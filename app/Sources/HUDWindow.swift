import AppKit
import CoreGraphics

// MARK: - HUD 吐司

/// 一个吐司的内容：从 AX 通知里来的动作名 + 键位组合，
/// 以及 v2 才会填上的 Windows 对照。
struct ToastContent {
    let action: String        // "Save"
    let combo: String         // "⌘S"
    let windowsEquivalent: String?  // Windows 侧键位，如 "Ctrl+S"；查不到时为 nil
    var sourceApp: String = ""
    /// 第三行解释（issue #11）。为空时不占位。
    ///
    /// 为什么是「第三行小字」而不是把它塞进 `action`：动作名是这一层的主信息，
    /// 字号和位置都在告诉用户「先看这个」。解释性文案混进标题会让两者都变弱。
    var note: String = ""
}

/// 深模块：调用方只说 `show(content)`，不需要知道
/// 窗口层级、毛玻璃材质、堆叠策略、淡出计时中的任何一件事。
final class HUDController {

    private var visible: [ToastWindow] = []
    private let duration: TimeInterval = 1.6
    private let fadeDuration: TimeInterval = 0.35
    private let gap: CGFloat = 8

    /// 自测观察口（app/e2e.sh 用）：当前仍被管理的吐司，按堆叠顺序排列。
    ///
    /// 这个 App 最危险的失败模式是「代码走到了、但屏幕上什么都没有」——
    /// 那是不可见的失败。所以哪怕它是一个深模块，也必须留一个**可被断言**的
    /// 观察口：否则端到端测试只能相信日志，而日志无法区分
    /// 「调了 orderFrontRegardless」和「窗口真的进了 Window Server」。
    var activeToasts: [ToastWindow] { visible }

    /// 连续触发时纵向堆叠，新的在上。
    func show(_ content: ToastContent) {
        let win = ToastWindow(content: content)
        visible.append(win)
        layout()
        win.present()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak win] in
            guard let self, let win else { return }
            win.fadeOut(self.fadeDuration) { [weak self] in
                guard let self else { return }
                win.orderOut(nil)
                self.visible.removeAll { $0 === win }
                self.layout()
            }
        }
    }

    /// 最新的一张贴在屏幕中线下方，旧的依次往下排。
    ///
    /// 遍历顺序必须**倒序**：`visible` 是「旧 → 新」，顺序遍历会让最新的一张
    /// 落在最下面——与「新的在上」正好相反。这是端到端自证（app/e2e.sh）
    /// 抓到的真 bug，`STACK.NEW_ON_TOP` 就是它的看门狗。
    private func layout() {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        var top = vis.midY
        for win in visible.reversed() {     // 新的在前 → 最新的一张居中
            let h = win.frame.height
            win.setFrameOrigin(NSPoint(x: vis.midX - win.frame.width / 2, y: top - h / 2))
            top -= h + gap
        }
    }
}

// MARK: - Window Server 侧的事实

/// 从 Window Server 反查「本进程的哪些窗口**真的**在屏幕上」。
///
/// 为什么必须有这一层：`NSWindow.isVisible` 只是 App 自己的意愿。
/// 一旦某个 AppKit 隐式行为（例如 NSPanel 默认 `hidesOnDeactivate = true`
/// 在 accessory App 上永不 active）把窗口藏起来，`isVisible` 仍会是 true，
/// 而屏幕上什么都没有——历史上这个 App 就是栽在这里（commit 7e9b9a5）。
/// 端到端自证要断言的正是**可用性事实**，不是意愿。
///
/// 只枚举自己进程的窗口，不需要「屏幕录制」权限。
enum WindowServer {

    /// Window Server 对某个窗口的描述。
    struct Info {
        let number: CGWindowID   // 与 NSWindow.windowNumber 同域
        let layer: Int
        let alpha: Double
        let size: CGSize
    }

    static func onScreenWindows(pid: pid_t = getpid()) -> [Info] {
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let owner = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let number = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            var size = CGSize.zero
            if let b = d[kCGWindowBounds as String] as? [String: Any] {
                let w = (b["Width"] as? NSNumber)?.doubleValue ?? 0
                let h = (b["Height"] as? NSNumber)?.doubleValue ?? 0
                size = CGSize(width: w, height: h)
            }
            return Info(number: CGWindowID(number), layer: layer, alpha: alpha, size: size)
        }
    }

    /// 某个 NSWindow 当前是否真的在 Window Server 的「屏幕上」列表里。
    static func onScreenInfo(for window: NSWindow) -> Info? {
        guard window.windowNumber != 0 else { return nil }
        return onScreenWindows().first { $0.number == CGWindowID(window.windowNumber) }
    }
}

// MARK: - 单个吐司窗口

final class ToastWindow: NSPanel {

    /// 这个窗口展示的内容。自测要断言「最上面那张是最后触发的」，
    /// 就必须能从窗口本身反查到它是哪一句动作。
    let content: ToastContent

    init(content: ToastContent) {
        self.content = content
        let view = ToastView(content: content)
        let size = view.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        // 不抢焦点：nonactivating + borderless + ignoresMouseEvents
        isFloatingPanel = true
        // NSPanel 默认 hidesOnDeactivate = true，而 accessory App 永远不会成为
        // active App——不关掉这个，吐司一弹出就会立刻自己被藏起来。
        hidesOnDeactivate = false
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = view
        alphaValue = 0

        // 尊重「减弱动态效果」：系统开了就不做缩放动画
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 视图里**真实画出来**的文字（递归子视图）。
    /// 端到端要断言的不只是「有个窗口」，而是「卡片上的字就是这次按键解析出的动作名」——
    /// 否则一个空壳窗口也能让「窗口存在」的断言变绿。
    var displayedTexts: [String] {
        guard let root = contentView else { return [] }
        var out: [String] = []
        func walk(_ v: NSView) {
            if let tf = v as? NSTextField, !tf.stringValue.isEmpty { out.append(tf.stringValue) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    func present() {
        orderFrontRegardless()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            contentView?.layer?.transform = CATransform3DIdentity
        }
    }

    func fadeOut(_ duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 0
        } completionHandler: {
            completion()
        }
    }
}

// MARK: - 吐司的视觉

final class ToastView: NSView {

    init(content: ToastContent) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let actionLabel = NSTextField(labelWithString: content.action)
        actionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        actionLabel.textColor = .labelColor
        actionLabel.alignment = .center
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.maximumNumberOfLines = 1
        actionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionLabel.setContentHuggingPriority(.required, for: .horizontal)
        pinToUntruncatedWidth(actionLabel)
        stack.addArrangedSubview(actionLabel)

        if !content.combo.isEmpty {
            let comboLabel = NSTextField(labelWithString: content.combo)
            comboLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            comboLabel.textColor = .secondaryLabelColor
            comboLabel.alignment = .center
            // 组合串同理：`fn⌃⌥⇧←` 这种长组合被截断就等于显示错误信息。
            comboLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            pinToUntruncatedWidth(comboLabel)
            stack.addArrangedSubview(comboLabel)
        }

        // 第二行：Windows 对照。查不到时整行不占位——空一行比没有更让人在意。
        if let win = content.windowsEquivalent {
            let winLabel = NSTextField(labelWithString: "Windows: \(win)")
            winLabel.font = .systemFont(ofSize: 11, weight: .regular)
            winLabel.textColor = .tertiaryLabelColor
            winLabel.alignment = .center
            stack.addArrangedSubview(winLabel)
        }

        // 第三行：为什么没有动作名（issue #11）。比 Windows 对照更贴近主信息，
        // 用 secondary 而不是 tertiary —— 它是解释，不是补充。
        if !content.note.isEmpty {
            let noteLabel = NSTextField(wrappingLabelWithString: content.note)
            noteLabel.font = .systemFont(ofSize: 11, weight: .regular)
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.alignment = .center
            noteLabel.preferredMaxLayoutWidth = 320
            stack.addArrangedSubview(noteLabel)
        }

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // MARK: 不截断

    /// 让单行 label **真的不截断**（`--render-toast` 抓到过「平铺到左…」）。
    ///
    /// 这不是压缩阻力的问题——阻力早就锁到 required 了。真正的坑是
    /// `NSTextField(labelWithString:)` 的 `intrinsicContentSize` 比**它自己画一遍**
    /// 所需的宽度窄约 4pt（实测：17pt semibold「平铺到左半屏」
    /// intrinsic=101.5，`cell.cellSize`=105.1）。Auto Layout 正好把 label 铺到
    /// 那个 intrinsic 宽度上，于是 cell 在**恰好差一点点**的地方开始省略。
    /// 「刚好等于 intrinsic」是会被截断的宽度——这与直觉相反，必须显式兜住。
    ///
    /// 取 `cellSize`（含 cell 自己的左右内边距）而不是 `attributedStringValue.size()`
    /// 再手加常数：前者就是 cell 实际拿去画的宽度，改字号时不用改这个函数。
    static func untruncatedWidth(for label: NSTextField) -> CGFloat? {
        guard let cell = label.cell else { return nil }
        let needed = cell.cellSize.width
        guard needed > 0 else { return nil }
        // 只要 `ceil`：实测 105.1 铺到 105 仍会省略、铺到 106 就完整，所以
        // 向上取整正好够。**不要加额外常数**——多出来的 1pt 会把窗口宽度推成
        // 奇数，而 `HUDController.layout()` 用的 `midX - width/2` 在奇数宽度下
        // 必然落在 .5 上，端到端 `STACK.CENTERED_X` 就会假红（实测踩过）。
        return ceil(needed)
    }

    private func pinToUntruncatedWidth(_ label: NSTextField) {
        guard let w = Self.untruncatedWidth(for: label) else { return }
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: w).isActive = true
    }

    override var fittingSize: NSSize {
        let s = super.fittingSize
        return NSSize(width: max(120, s.width), height: s.height)
    }
}

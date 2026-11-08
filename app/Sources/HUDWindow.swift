import AppKit

// MARK: - HUD 吐司

/// 一个吐司的内容：从 AX 通知里来的动作名 + 键位组合，
/// 以及 v2 才会填上的 Windows 对照。
struct ToastContent {
    let action: String        // "Save"
    let combo: String         // "⌘S"
    let windowsEquivalent: String?  // v2 钩子，v1 恒为 nil
    var sourceApp: String = ""
}

/// 深模块：调用方只说 `show(content)`，不需要知道
/// 窗口层级、毛玻璃材质、堆叠策略、淡出计时中的任何一件事。
final class HUDController {

    private var visible: [ToastWindow] = []
    private let duration: TimeInterval = 1.6
    private let fadeDuration: TimeInterval = 0.35
    private let gap: CGFloat = 8

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

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        var y = vis.midY
        for win in visible {
            let h = win.frame.height
            let x = vis.midX - win.frame.width / 2
            y -= h / 2
            win.setFrameOrigin(NSPoint(x: x, y: y))
            y -= h / 2 + gap
        }
    }
}

// MARK: - 单个吐司窗口

final class ToastWindow: NSPanel {

    init(content: ToastContent) {
        let view = ToastView(content: content)
        let size = view.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        // 不抢焦点：nonactivating + borderless + ignoresMouseEvents
        isFloatingPanel = true
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
        stack.addArrangedSubview(actionLabel)

        if !content.combo.isEmpty {
            let comboLabel = NSTextField(labelWithString: content.combo)
            comboLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            comboLabel.textColor = .secondaryLabelColor
            comboLabel.alignment = .center
            stack.addArrangedSubview(comboLabel)
        }

        // v2 钩子：有 Windows 对照时显示第二行。v1 永远走不到这里。
        if let win = content.windowsEquivalent {
            let winLabel = NSTextField(labelWithString: "Windows: \(win)")
            winLabel.font = .systemFont(ofSize: 11, weight: .regular)
            winLabel.textColor = .tertiaryLabelColor
            winLabel.alignment = .center
            stack.addArrangedSubview(winLabel)
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

    override var fittingSize: NSSize {
        let s = super.fittingSize
        return NSSize(width: max(120, s.width), height: s.height)
    }
}

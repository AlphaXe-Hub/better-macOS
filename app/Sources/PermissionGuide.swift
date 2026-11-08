import AppKit

// MARK: - 权限引导窗口

/// 深模块：`show()` 一句话就能拉起整套引导，
/// 调用方不需要知道拖拽目标、轮询计时、图标渲染中的任何一件事。
///
/// **为什么是拖拽而不是"点一下自动出现"**：
/// `AXIsProcessTrustedWithOptions(prompt: true)` 对 ad-hoc 签名的 App
/// 经常不把条目写进系统设置的列表——用户点进去看到空列表，会以为我们坏了。
/// 拖拽不依赖任何前提：App 本体就在桌面上，拖进去一定成功。
final class PermissionGuideWindow: NSPanel {

    /// 用户在窗口里完成授权后回调（用于刷新主界面状态）。
    var onGranted: (() -> Void)?

    private var pollTimer: Timer?
    private var wasGranted = false
    /// 上一次见到的授权状态。只在**变化时**才重排 UI，避免每秒闪一次。
    private var lastGrantedState: Bool?

    private let iconWell = IconWellView()
    private var titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stepsStack = NSStackView()
    private var subtitleLabel = NSTextField(labelWithString: "")
    private var openBtn = NSButton()
    private var healthBtn = NSButton()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "开启辅助功能权限"
        level = .floating
        hidesOnDeactivate = false   // accessory App 必须显式关掉
        isReleasedWhenClosed = false
        buildUI()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 界面

    private func buildUI() {
        let container = NSView()
        contentView = container

        titleLabel = NSTextField(labelWithString: "把下面的图标拖进系统设置")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        subtitleLabel = NSTextField(wrappingLabelWithString:
            "macOS 不允许 App 自己给自己授权。你需要把 better-macOS 拖到「辅助功能」列表里。\n" +
            "这是唯一可靠的方式——点「去授权」有时不会把我们加进列表。")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = 510
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.onDragStarted = { [weak self] in self?.handleDragStarted() }
        container.addSubview(iconWell)

        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 10
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stepsStack)
        buildSteps()

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        openBtn = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(openBtn)

        healthBtn = NSButton(title: "检查是否生效", target: self, action: #selector(recheckNow))
        healthBtn.bezelStyle = .rounded
        healthBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(healthBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            iconWell.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            iconWell.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconWell.widthAnchor.constraint(equalToConstant: 132),
            iconWell.heightAnchor.constraint(equalToConstant: 132),

            stepsStack.topAnchor.constraint(equalTo: iconWell.bottomAnchor, constant: 18),
            stepsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stepsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: stepsStack.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            // 按钮紧跟在状态行下面，不再钉在窗口底部（那会留出一大片空白）
            openBtn.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            openBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            openBtn.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),

            healthBtn.centerYAnchor.constraint(equalTo: openBtn.centerYAnchor),
            healthBtn.trailingAnchor.constraint(equalTo: openBtn.leadingAnchor, constant: -10),
        ])

        // 必须等所有控件和约束都就位后再决定显示哪个状态，
        // 否则"已授权"分支里的 removeFromSuperview 会作用于尚未创建的按钮。
        refreshStatus()
    }

    private func buildSteps() {
        let steps: [(String, String)] = [
            ("1", "点下面的「打开系统设置」，会跳到「隐私与安全性 → 辅助功能」"),
            ("2", "把上面的图标**拖进**那个列表（或用列表下方的 ＋ 号选中 App）"),
            ("3", "回来这里，状态会自动变成「已授权」"),
        ]
        for (num, text) in steps {
            let badge = NSTextField(labelWithString: num)
            badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 9
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(equalToConstant: 18).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let label = InlineText.label(text,
                                         font: .systemFont(ofSize: 12),
                                         color: .labelColor,
                                         wrapping: true,
                                         maxWidth: 470)
            let row = NSStackView(views: [badge, label])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            stepsStack.addArrangedSubview(row)
        }
    }

    // MARK: 状态

    private func refreshStatus() {
        if Permissions.hasAccessibility {
            // 已授权：整个引导失去意义，切成完成态，别让用户对着已完成的步骤发呆
            titleLabel.stringValue = "已经可以用了"
            subtitleLabel.stringValue = "权限已生效。按任意带 ⌘ 的快捷键试试，屏幕上会浮出这个动作的名字。"
            statusLabel.stringValue = ""
            iconWell.showSuccess()
            stepsStack.isHidden = true
            openBtn.removeFromSuperview()
            healthBtn.removeFromSuperview()
            resizeToFit(width: 560)
        } else {
            titleLabel.stringValue = "把下面的图标拖进系统设置"
            subtitleLabel.stringValue =
                "macOS 不允许 App 自己给自己授权。你需要把 better-macOS 拖到「辅助功能」列表里。\n" +
                "这是唯一可靠的方式——点「去授权」有时不会把我们加进列表。"
            statusLabel.stringValue = "○ 当前状态：未授权"
            statusLabel.textColor = .secondaryLabelColor
            stepsStack.isHidden = false
            resizeToFit(width: 560)
        }
    }

    private func startPolling() {
        // 用户拖完之后系统会立刻写入 TCC，但我们不知道时机，所以轮询。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // 必须加进 `.common`：窗口拖动、菜单打开等 RunLoop 模式切换时
        // 默认模式（.default）的 timer 会停摆。（同一坑在 FrontmostAppTracker 里已踩过一次）
        if let t = pollTimer {
            RunLoop.main.add(t, forMode: .common)
        }

        // 轮询之外再补一条：App 重新拿到焦点时立刻查一次。
        //
        // **为什么单靠 timer 不够**：Timer 挂在主 RunLoop 上，而「系统设置」成为前台
        // 时我们并没有活跃；系统设置的「辅助功能」面板里点开关、拖入 App 都是
        // 在系统设置进程里发生。这段时间我们的 timer 其实还在跑（系统设置不会挂起别的进程），
        // 但系统的 TCC 写入 + 我们的下一次 tick 之间最多会有 1 秒空窗。
        // 用户拖完立刻切回来时，这 1 秒空窗会让人以为「没反应」。
        // 用 didBecomeActive 做一次即时检查，把空窗压到 0。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 立刻检查一次授权状态（供 timer / 激活通知 / 手动按钮共用）。
    @objc private func appDidBecomeActive() { poll() }

    private func poll() {
        let granted = Permissions.hasAccessibility
        // 状态没变就不重排 UI：每秒重建一次 label/约束会让窗口持续闪烁。
        if granted != lastGrantedState {
            lastGrantedState = granted
            refreshStatus()
        }
        if granted && !wasGranted {
            wasGranted = true
            handleGranted()
        }
    }

    private func handleGranted() {
        NSLog("[better-macOS] accessibility granted")
        onGranted?()
        // 授权后停一会儿再关，让用户看到成功状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.close()
        }
    }

    /// 用户开始拖拽图标时，顺手把系统设置打开——省一步。
    private func handleDragStarted() {
        openSettings()
    }

    /// 让窗口高度贴合内容：固定高度会让隐藏掉的控件仍然占位。
    private func resizeToFit(width: CGFloat) {
        guard let container = contentView else { return }
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        guard fitting.height > 10 else { return }
        var frame = self.frame
        let newHeight = fitting.height
        let sizeChanged = abs(frame.height - max(newHeight, 300)) > 1
        frame.size = NSSize(width: width, height: max(newHeight, 300))
        setFrame(frame, display: true, animate: false)
        container.needsLayout = true
        // 尺寸变了、而且用户已经能看见这个窗口 → 重新算一次避让位置，
        // 否则「授权后切成完成态（窗口变矮）」会把刚排好的位置又挪重叠。
        if sizeChanged && isVisible {
            positionAvoidingOtherWindows()
        }
    }

    // MARK: 动作

    @objc private func openSettings() {
        Permissions.attemptSystemPrompt()   // 尝试让条目自动出现（不保证）
        Permissions.openAccessibilitySettings()
    }

    @objc private func recheckNow() {
        refreshStatus()
        if Permissions.hasAccessibility { handleGranted() }
    }

    override func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        super.close()
    }

    func present() {
        positionAvoidingOtherWindows()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    // MARK: 定位

    /// 首次启动时 `AppDelegate` 会先开「迁移清单」（620×640 居中），0.6 秒后再开我们。
    /// 两个窗口都 `center()` 的话会**几乎完全重叠**（实测重叠 99.5%），
    /// 用户只看到上面那个，以为另一个没打开。
    ///
    /// 这里不要求 AppDelegate 配合（那是别人的写域），而是让引导窗口自己
    /// **量一下屏幕上已有哪些窗口**，再挑一个重叠最小的位置。
    ///
    /// **必须说清的限制**：窗口够大时（例如 1920 宽）右侧能整块放下，重叠为 0；
    /// 但在 1470×923 这类屏幕上，一个居中的 620×672 窗口左右只剩 425pt，
    /// 而我们最窄也要 560pt——**几何上不存在不重叠的位置**。
    /// 那种情况下这里退化为「挑重叠最小的位置」（贴角，约 20%），
    /// 真正的根治是不要在未授权时同时开两个窗口，见 docs/ax-electron.md 的说明。
    private func positionAvoidingOtherWindows() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size

        let others = NSApp.windows.filter {
            $0 !== self && $0.isVisible && $0.frame.width > 200 && $0.frame.height > 200
        }
        guard let top = others.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            center()
            return
        }

        let gap: CGFloat = 24
        let f = top.frame

        // 候选位置。不写死「右边/左边」——在窄屏上那两种都放不下，
        // 而且真正的最优点常常是「屏幕边角里那个刚好只擦到邻居一角的位置」。
        // 做法：把窗口可以贴的 x / y 关键线做笛卡尔积。
        //
        // 候选 x：屏幕左边缘 / 左内边、右边缘 / 右内边、邻居两侧外侧、居中
        // 候选 y：屏幕下边缘 / 下内边、上边缘 / 上内边、邻居上下外侧、与邻居底对齐
        //
        // 贴边（不带 gap）也保留：`visibleFrame` 已经扣掉了菜单栏和 Dock，
        // 贴着它的边是正常窗口行为，而且窄屏上往往就是最优解。
        let xs: [CGFloat] = [
            visible.minX, visible.minX + gap,
            visible.maxX - size.width, visible.maxX - gap - size.width,
            f.minX - gap - size.width,
            f.maxX + gap,
            visible.midX - size.width / 2,
        ]
        let ys: [CGFloat] = [
            visible.minY, visible.minY + gap,
            visible.maxY - size.height, visible.maxY - gap - size.height,
            f.minY - gap - size.height,
            f.maxY + gap,
            f.minY,
        ]

        // 只保留完全落在可见区域内的位置（屏幕外 = 用户够不到，比重叠更糟）
        var onScreen: [NSPoint] = []
        for x in xs {
            for y in ys where y <= visible.maxY - size.height && y >= visible.minY {
                let r = NSRect(x: x, y: y, width: size.width, height: size.height)
                if visible.contains(r) { onScreen.append(NSPoint(x: x, y: y)) }
            }
        }
        guard !onScreen.isEmpty else { center(); return }

        func overlapArea(_ origin: NSPoint) -> CGFloat {
            let r = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
            var sum: CGFloat = 0
            for w in others {
                let i = w.frame.intersection(r)
                if !i.isNull { sum += i.width * i.height }
            }
            return sum
        }

        // 选重叠最小的；并列时选离屏幕中心最近的（视觉上更自然）
        let best = onScreen.min { a, b in
            let oa = overlapArea(a), ob = overlapArea(b)
            if abs(oa - ob) > 1 { return oa < ob }
            let da = hypot(a.x - visible.midX, a.y - visible.midY)
            let db = hypot(b.x - visible.midX, b.y - visible.midY)
            return da < db
        }!
        setFrame(NSRect(x: best.x, y: best.y, width: size.width, height: size.height), display: true)
    }

}

// MARK: - 可拖拽的 App 图标

/// 这个视图的唯一职责：显示自己的图标，并让它能被拖出到系统设置。
/// 用一个真 NSImageView + NSDraggingSource，而不是自绘——系统设置认的是
/// 标准的 file URL 拖拽。
final class IconWellView: NSView, NSDraggingSource {

    var onDragStarted: (() -> Void)?
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        imageView.image = Self.appIcon(128)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// 取 App 自己的图标。Info.plist 里没有 CFBundleIconFile 时，
    /// NSWorkspace 仍会返回系统生成的通用图标——可以接受，但我们会自己画一个兜底。
    static func appIcon(_ size: CGFloat) -> NSImage? {
        if let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) as NSImage? {
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        return NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
    }

    func showSuccess() {
        layer?.borderColor = NSColor.systemGreen.cgColor
        layer?.borderWidth = 2
    }

    // MARK: 拖拽

    override func mouseDragged(with event: NSEvent) {
        guard let url = Permissions.appBundleURL else { return }
        onDragStarted?()

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = bounds.size
        // 拖拽时显示的图像：缩小一点，且不要盖住鼠标
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              contents: Self.appIcon(size.width))

        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 系统设置的授权列表接受 copy
        return .copy
    }
}

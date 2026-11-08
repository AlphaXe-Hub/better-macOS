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
        center()
        buildUI()
        startPolling()
    }

    deinit { pollTimer?.invalidate() }

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
        // 1 秒一次足够，且开销可以忽略。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = Permissions.hasAccessibility
            self.refreshStatus()
            if granted && !self.wasGranted {
                self.wasGranted = true
                self.handleGranted()
            }
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
        frame.size = NSSize(width: width, height: max(newHeight, 300))
        setFrame(frame, display: true, animate: false)
        container.needsLayout = true
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
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
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

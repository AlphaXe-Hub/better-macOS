import AppKit

// MARK: - 偏好设置窗口

/// 用代码搭的偏好设置：一个 AppKit 窗口 + 竖直堆叠的分区。
/// 不用 SwiftUI 是为了把依赖压到 AppKit 一层（CLT-only 构建更稳），
/// 且这个界面本来就只有「开关 + 说明」两种元素。
final class PreferencesWindow: NSWindow {

    private let registry: CorrectionRegistry
    private var correctionSwitches: [String: NSSwitch] = [:]

    init(registry: CorrectionRegistry) {
        self.registry = registry
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "better-macOS"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func buildUI() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        contentView = scroll

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // ——— 权限状态 ———
        stack.addArrangedSubview(sectionTitle("权限"))
        stack.addArrangedSubview(permissionRow())

        // ——— 学习层 ———
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("学习：看清你按了什么"))
        stack.addArrangedSubview(bodyText(
            "按下一个绑定到菜单的快捷键时，屏幕中央会浮出一个提示，告诉你这个动作的名字。\n" +
            "按 ⌥⌘K 打开当前 App 的完整快捷键面板。"))
        stack.addArrangedSubview(hudRow())

        // ——— 修正层 ———
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("修正：让 Mac 更像个能干活的地方"))
        for c in registry.corrections {
            stack.addArrangedSubview(correctionRow(c))
        }

        // ——— 边界 ———
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("我们看不到什么"))
        stack.addArrangedSubview(bodyText(
            "• 系统级快捷键（⌘Space、⇧⌘5、⌘Tab）——macOS 在 App 之前就处理掉了\n" +
            "• 没有绑定菜单项的快捷键（App 内部自己处理的按键）\n" +
            "• 用 Carbon 注册的老式全局热键\n\n" +
            "这不是 bug。与其假装什么都能看见，不如把边界说清楚。"))
    }

    // MARK: 组件

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .labelColor
        return l
    }

    private func bodyText(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 500
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return b
    }

    private func permissionRow() -> NSView {
        let granted = Permissions.hasAccessibility
        let label = NSTextField(labelWithString: granted
            ? "✓ 已授予辅助功能权限"
            : "✗ 未授予辅助功能权限 —— 吐司和面板都不会工作")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = granted ? .systemGreen : .systemOrange

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.spacing = 10
        if !granted {
            let btn = NSButton(title: "如何授权 →", target: self, action: #selector(openPerms))
            btn.bezelStyle = .rounded
            row.addArrangedSubview(btn)
        }
        return row
    }

    private func hudRow() -> NSView {
        let label = NSTextField(labelWithString: "吐司提示")
        let sw = NSSwitch()
        sw.state = UserDefaults.standard.object(forKey: "hud.enabled") as? Bool ?? true ? .on : .off
        sw.target = self
        sw.action = #selector(toggleHUD(_:))
        let row = NSStackView(views: [label, sw])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return row
    }

    private func correctionRow(_ c: Correction) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)

        let sub = NSTextField(wrappingLabelWithString: c.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 420

        let sw = NSSwitch()
        sw.state = c.isOn ? .on : .off
        sw.target = self
        sw.action = #selector(toggleCorrection(_:))
        sw.identifier = NSUserInterfaceItemIdentifier(c.id)
        correctionSwitches[c.id] = sw

        let perm = NSTextField(labelWithString: c.requiredPermission.description)
        perm.font = .systemFont(ofSize: 10)
        perm.textColor = .tertiaryLabelColor

        let text = NSStackView(views: [title, sub, perm])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [text, sw])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 500),
        ])
        return box
    }

    // MARK: 动作

    /// 由 AppDelegate 注入：打开拖拽式权限引导。
    var onRequestPermission: (() -> Void)?

    @objc private func openPerms() {
        onRequestPermission?()
    }

    @objc private func toggleHUD(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hud.enabled")
    }

    @objc private func toggleCorrection(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue,
              let c = registry.corrections.first(where: { $0.id == id }) else { return }
        registry.setEnabled(c, sender.state == .on)
        sender.state = c.isOn ? .on : .off
    }
}

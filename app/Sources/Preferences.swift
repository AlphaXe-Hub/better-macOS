import AppKit

// MARK: - 偏好设置窗口

/// NSScrollView 的 documentView。
/// 必须翻转坐标系：非翻转时原点在左下角，内容比可视区高时初始滚动位置会停在
/// 文档底部（一打开设置就看见最后一段），翻转后才从顶部开始读。
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
        level = .floating              // 和其他窗口一致，不会被别的 App 盖住
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

        let doc = FlippedDocumentView()
        doc.addSubview(stack)
        scroll.documentView = doc
        // NSScrollView 不会替 documentView 推导尺寸：documentView 默认靠
        // autoresizing 跟着 clipView 走，一旦转成 Auto Layout，宽度就没有人来给，
        // 会被算成 0 —— 于是整条约束链在 doc 处断掉，窗口 560x620 实际渲染成
        // 0x620（外观就是「点设置没有任何窗口出现」）。
        // 所以这里显式把 doc 的宽度接到 clipView（不是 scrollView：后者含滚动条），
        // 高度则交给 stack 的内容撑开 —— 故意不钉 doc.bottom，内容比窗口高时才滚得动。
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
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

        // ——— 点击教练 ———
        // 单独一节而不是并进「吐司提示」：它是**另一个触发器**（鼠标 vs 键盘），
        // 用户想关掉噪音时得能分清自己关的是哪一条。
        stack.addArrangedSubview(sectionTitle("点击教练"))
        stack.addArrangedSubview(bodyText(
            "你在菜单里用鼠标点「文件 → 存储」时，浮出一句「存储 ⌘S」。\n" +
            "目的是把「点点点」换成快捷键——刚点完的那一刻，是你最需要知道答案的时候。\n\n" +
            "**同一个动作最多提示 3 次**，之后就安静了。只有带快捷键的菜单项会被提示；\n" +
            "点工具栏按钮、点空白处都不会有任何反应。"))
        stack.addArrangedSubview(coachRow())

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
            "• 系统级快捷键（下表）——由 macOS 自己处理，不登记在任何 App 的菜单里\n" +
            "• 没有绑定菜单项的快捷键（App 内部自己处理的按键）\n" +
            "• 用 Carbon 注册的老式全局热键\n\n" +
            "这不是 bug。与其假装什么都能看见，不如把边界说清楚。"))
        stack.addArrangedSubview(systemShortcutList())

        // ——— 关于 fn ———
        // 第 ① 层的真 bug 已修（fn 现在会显示在组合里），但用户仍会好奇
        // 「fn← 到底算什么」。这里给答案，并明确它**不在**系统快捷键表里。
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("关于 fn（功能键）"))
        stack.addArrangedSubview(bodyText(
            "fn 现在会参与组合识别：按 fn⌃← 显示 fn⌃←，按 ⌃← 显示 ⌃←，两者不再混为一谈。\n\n" +
            "但**我们只负责显示你按了什么，不猜它做了什么**：\n" +
            "• fn← / fn→ / fn↑ / fn↓ 由当前打开的那个 App 处理（文本编辑里是行首行尾、翻页），\n" +
            "  所以它们不算系统级快捷键，查不到动作名时我们说「这个 App 没有绑定」。\n" +
            "• fn 组合不一定是系统键——系统键的判据是**在上面那张清单里**，不是「带 fn」。"))
    }

    /// 系统级快捷键清单（issue #11 第 5 条）。
    ///
    /// 为什么要在设置页里**逐条列出来**，而不是只写一句「有些键我们看不到」：
    /// 用户的实际问题是「我按了 ⌃↑ 怎么没反应」，一句抽象的免责声明回答不了它。
    /// 但他能在这张表里**找到 ⌃↑ 并看到它叫什么**——那一刻困惑就消失了。
    private func systemShortcutList() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 10
        box.translatesAutoresizingMaskIntoConstraints = false

        for section in SystemShortcuts.grouped() {
            let head = NSTextField(labelWithString: section.group)
            head.font = .systemFont(ofSize: 11, weight: .semibold)
            head.textColor = .labelColor
            box.addArrangedSubview(head)

            for e in section.entries {
                let combo = NSTextField(labelWithString: e.combo)
                combo.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                combo.textColor = .labelColor
                combo.setContentHuggingPriority(.required, for: .horizontal)
                combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true

                let name = NSTextField(labelWithString: e.name)
                name.font = .systemFont(ofSize: 11)
                name.textColor = .secondaryLabelColor

                let row = NSStackView(views: [combo, name])
                row.orientation = .horizontal
                row.spacing = 12
                box.addArrangedSubview(row)
            }
        }

        let foot = bodyText("出处：Apple 官方快捷键文档（Mac keyboard shortcuts / "
                            + "Window tiling / Work in multiple spaces）。"
                            + "完整清单在系统设置里，这里只列迁移中最常撞上的那些。")
        box.addArrangedSubview(foot)
        return box
    }

    // MARK: 组件

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .labelColor
        return l
    }

    /// 说明文字。走 `InlineText`，所以文案里可以写 `**强调**`——
    /// 否则星号会原样出现在界面上（`--render` 渲染出来抓到过）。
    private func bodyText(_ s: String) -> NSTextField {
        let font = NSFont.systemFont(ofSize: 12)
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = InlineText.attributed(s, font: font, color: .secondaryLabelColor)
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

    /// 点击教练开关。默认开——它是这个产品最核心的教学入口，
    /// 默认关掉等于让用户永远发现不了。
    private func coachRow() -> NSView {
        let label = NSTextField(labelWithString: "用鼠标点菜单时提示快捷键")
        let sw = NSSwitch()
        sw.state = (UserDefaults.standard.object(forKey: "coach.enabled") as? Bool ?? true) ? .on : .off
        sw.target = self
        sw.action = #selector(toggleCoach(_:))
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

    /// 由 AppDelegate 注入：点击教练开关变化后重建事件通道。
    var onCoachSettingChanged: (() -> Void)?

    @objc private func openPerms() {
        onRequestPermission?()
    }

    @objc private func toggleHUD(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hud.enabled")
    }

    /// 点击教练开关。改完要**立刻**重建事件通道——只写 UserDefaults 的话，
    /// 用户关掉开关后点击仍在被监听，直到下次重启才生效，那是能感觉到的 bug。
    @objc private func toggleCoach(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "coach.enabled")
        onCoachSettingChanged?()
    }

    @objc private func toggleCorrection(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue,
              let c = registry.corrections.first(where: { $0.id == id }) else { return }
        registry.setEnabled(c, sender.state == .on)
        sender.state = c.isOn ? .on : .off
    }
}

import AppKit

// MARK: - 迁移清单窗口

/// 深模块：给它一个目录，它负责分组、渲染、以及"能修的就地修"。
/// 调用方不需要知道 NSTableView 或任何布局细节。
///
/// **这个窗口存在的理由**：调研发现现有工具都假设用户已经会用 Mac、
/// 只是想要更细的控制；迁移用户的真实状态是"我不知道该改什么"。
/// 一个动作清单（而不是一堆开关）才是那个形态。
final class MigrationGuideWindow: NSPanel {

    private let registry: CorrectionRegistry
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var rows: [Row] = []

    private enum Row {
        case header(String)
        case entry(MigrationEntry)
    }

    init(registry: CorrectionRegistry) {
        self.registry = registry
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "从 Windows 来？从这里开始"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        level = .floating
        center()
        buildRows()
        buildUI()
    }

    private func buildRows() {
        var out: [Row] = []
        for (category, entries) in MigrationCatalog.grouped() {
            out.append(.header(category))
            for e in entries { out.append(.entry(e)) }
        }
        rows = out
    }

    private func buildUI() {
        let container = NSView()
        contentView = container

        let permBar = makePermissionBar()
        container.addSubview(permBar)

        let header = NSTextField(wrappingLabelWithString:
            "这些是 Windows 用户最常撞上的差异。每条都分三行：Mac 现在怎么做、你在 Windows 上怎么做、以及我们能做什么。\n" +
            "蓝色 = 系统设置里能改，我们给出具体路径。橙色 = 我们不做，并说清楚为什么——藏起来反而会让你以为是自己没找到。")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.preferredMaxLayoutWidth = 580
        container.addSubview(header)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            permBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            permBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            permBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            header.topAnchor.constraint(equalTo: permBar.bottomAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// 权限条：只在未授权时出现，说清楚要什么、为什么、以及不授权会怎样。
    private func makePermissionBar() -> NSView {
        guard !Permissions.hasAccessibility else {
            let ok = NSTextField(labelWithString: "✓ 已获得辅助功能权限")
            ok.font = .systemFont(ofSize: 11)
            ok.textColor = .systemGreen
            return ok
        }

        let text = NSTextField(wrappingLabelWithString:
            "还需要一个「辅助功能」权限：用来读取当前 App 的菜单，这样按快捷键时才能告诉你触发的是哪个动作。\n" +
            "不读取你输入的内容，也不联网。不授权的话，下面这些开关和快捷键面板都不会工作。")
        text.font = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 440

        let btn = NSButton(title: "去授权", target: self, action: #selector(requestPerm))
        btn.bezelStyle = .rounded
        btn.controlSize = .small

        let row = NSStackView(views: [text, btn])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        return row
    }

    @objc private func requestPerm() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    // MARK: 就地修正

    func toggleFix(_ entry: MigrationEntry, on: Bool, sender: NSSwitch) {
        guard case .fixable(let cid) = entry.remedy,
              let c = registry.corrections.first(where: { $0.id == cid }) else { return }
        registry.setEnabled(c, on)
        sender.state = c.isOn ? .on : .off
        tableView.reloadData()
    }
}

extension MigrationGuideWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let name):
            let label = NSTextField(labelWithString: name.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let pad = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 12),
                label.topAnchor.constraint(equalTo: pad.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -2),
            ])
            return pad

        case .entry(let e):
            return makeEntryCell(e)
        }
    }

    private func makeEntryCell(_ e: MigrationEntry) -> NSView {
        let box = NSView()

        var titleViews: [NSView] = []
        let title = NSTextField(labelWithString: e.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        titleViews.append(title)
        if case .fixable = e.remedy {
            let badge = NSTextField(labelWithString: "这里就能打开")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .systemGreen
            titleViews.append(badge)
        }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let mac = labeledLine("Mac", e.macBehavior, color: .secondaryLabelColor)
        let win = labeledLine("Windows", e.windowsBehavior, color: .tertiaryLabelColor)

        let stack = NSStackView(views: [titleRow, mac, win])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        // 第三行：修复方式 / 指引 / 做不到的原因
        var trailing: NSView?
        switch e.remedy {
        case .fixable(let cid):
            if let c = registry.corrections.first(where: { $0.id == cid }) {
                let sw = NSSwitch()
                sw.state = c.isOn ? .on : .off
                sw.translatesAutoresizingMaskIntoConstraints = false
                let target = FixToggleTarget(window: self, entry: e, sender: sw)
                sw.target = target
                sw.action = #selector(FixToggleTarget.fire(_:))
                box.addSubview(sw)
                NSLayoutConstraint.activate([
                    sw.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
                    sw.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                ])
                objc_setAssociatedObject(sw, &FixToggleTarget.assocKey, target, .OBJC_ASSOCIATION_RETAIN)
                trailing = sw
            }

        case .guidance(let where_, let how):
            let g = labeledLine("怎么改", "\(where_) —— \(how)", color: .systemBlue)
            stack.addArrangedSubview(g)

        case .unfixable(let why):
            let u = labeledLine("我们不做", why, color: .systemOrange)
            stack.addArrangedSubview(u)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: (trailing?.leadingAnchor ?? box.trailingAnchor),
                                            constant: trailing == nil ? -14 : -12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }

    private func labeledLine(_ tag: String, _ text: String, color: NSColor) -> NSTextField {
        InlineText.label("\(tag)：\(text)",
                         font: .systemFont(ofSize: 11),
                         color: color,
                         wrapping: true,
                         maxWidth: 540)
    }
}

// MARK: - 开关代理

/// NSSwitch 的 target 需要是 Objective-C 对象且要能带上下文，
/// 用一个小代理把 entry 一起带过去。
final class FixToggleTarget: NSObject {
    static var assocKey: UInt8 = 0
    private weak var window: MigrationGuideWindow?
    private let entry: MigrationEntry
    private let sender: NSSwitch

    init(window: MigrationGuideWindow, entry: MigrationEntry, sender: NSSwitch) {
        self.window = window
        self.entry = entry
        self.sender = sender
    }

    @objc func fire(_ sw: NSSwitch) {
        window?.toggleFix(entry, on: sw.state == .on, sender: sw)
    }
}

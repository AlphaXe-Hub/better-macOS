import AppKit

// MARK: - 快捷键速查面板

/// 深模块：调用方给它一个「App 的菜单快照」，它负责分组、搜索、键盘导航、
/// 点击执行。调用方不需要知道 NSTableView 的任何细节。
final class ShortcutBrowserWindow: NSPanel {

    private let snapshot: MenuInventory.Snapshot
    private let onFire: (ShortcutItem) -> Void

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var filtered: [Row] = []

    struct Row {
        let item: ShortcutItem
        let isHeader: Bool
        /// 查表结果在这里算一次：视图复用时不重复查，也保证「行有没有第二行」
        /// 与「行高」用的是同一个判断。
        var windowsEquivalent: String? = nil

        init(item: ShortcutItem, isHeader: Bool) {
            self.item = item
            self.isHeader = isHeader
            self.windowsEquivalent = isHeader
                ? nil
                : WindowsEquivalents.lookup(combo: item.combo, action: item.title)
        }
    }

    init(snapshot: MenuInventory.Snapshot, onFire: @escaping (ShortcutItem) -> Void) {
        self.snapshot = snapshot
        self.onFire = onFire
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                   styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        title = "\(snapshot.appName) 的快捷键"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false   // accessory App 必须显式关掉，否则窗口一弹出就隐藏
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildRows()
        buildUI()
        // 不调 center() 会落在屏幕左下角（新建窗口的默认原点）
        center()
    }

    // MARK: 数据

    private func buildRows() {
        var out: [Row] = []
        for group in snapshot.groups {
            let items = snapshot.items.filter { $0.menuGroup == group }
            guard !items.isEmpty else { continue }
            out.append(Row(item: ShortcutItem(title: group, menuGroup: group, key: "",
                                              modifiers: [], enabled: true),
                           isHeader: true))
            for i in items {
                out.append(Row(item: i, isHeader: false))
            }
        }
        rows = out
        filtered = out
    }

    // MARK: 界面

    private func buildUI() {
        let container = NSView()
        contentView = container
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "搜索动作、键位或菜单名"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        container.addSubview(searchField)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(fireSelected)
        tableView.style = .plain

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        updateStatus()

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    /// 调试用（配合 `--render`）：把列表滚到第一条有 Windows 对照的行。
    /// 真实 App 的快照里，Apple 菜单排在最前面且没有 Windows 对应，
    /// 不滚一下就看不出第二行的版式。只在开发期渲染路径里调用。
    func scrollToFirstWindowsEquivalent() {
        guard let row = filtered.firstIndex(where: { $0.windowsEquivalent != nil }) else { return }
        tableView.scrollRowToVisible(row)
    }

    func focusSearch() {
        // 每次唤出都回到屏幕中央，避免上次拖到角落后再也找不到
        center()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        makeFirstResponder(searchField)
    }

    // MARK: 交互

    @objc private func searchChanged() { applyFilter(searchField.stringValue) }

    private func applyFilter(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            filtered = rows
            tableView.reloadData()
            updateStatus()
            return
        }
        // 过滤时把分组头去掉，只留命中的动作行，读起来更干净。
        filtered = rows.filter {
            guard !$0.isHeader else { return false }
            let i = $0.item
            return i.title.lowercased().contains(query)
                || i.combo.lowercased().contains(query)
                || i.menuGroup.lowercased().contains(query)
                || ($0.windowsEquivalent?.lowercased().contains(query) ?? false)
        }
        tableView.reloadData()
        updateStatus()
        if !filtered.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func updateStatus() {
        let total = snapshot.withShortcuts.count
        let shown = filtered.filter { !$0.isHeader }.count
        statusLabel.stringValue = searchField.stringValue.isEmpty
            ? "\(snapshot.appName) · \(total) 个快捷键 · 双击执行"
            : "匹配 \(shown) / \(total)"
    }

    @objc private func fireSelected() {
        let r = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard r >= 0, r < filtered.count, !filtered[r].isHeader else { return }
        onFire(filtered[r].item)
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func keyDown(with event: NSEvent) {
        // ↓ 从搜索框进列表
        if event.keyCode == 125, firstResponder === searchField {
            if !filtered.isEmpty {
                tableView.selectRowIndexes([0], byExtendingSelection: false)
                makeFirstResponder(tableView)
            }
            return
        }
        // ↑ 在列表顶部回到搜索框
        if event.keyCode == 126, firstResponder === tableView, tableView.selectedRow <= 0 {
            makeFirstResponder(searchField)
            return
        }
        if event.keyCode == 36 { fireSelected(); return }   // ⏎
        super.keyDown(with: event)
    }
}

extension ShortcutBrowserWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }
}

extension ShortcutBrowserWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let r = filtered[row]
        if r.isHeader {
            let label = NSTextField(labelWithString: r.item.title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let pad = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
            ])
            return pad
        }

        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.spacing = 12
        cell.alignment = .centerY

        let title = NSTextField(labelWithString: r.item.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = r.item.enabled ? .labelColor : .tertiaryLabelColor

        // 右侧：macOS 组合在上，Windows 对照在下（只有查得到时才画第二行）。
        // 用竖向 stack 而不是往行高里硬塞，行高由 delegate 统一给，版式不会被撑坏。
        let keys = NSStackView()
        keys.orientation = .vertical
        keys.alignment = .trailing
        keys.spacing = 0

        let combo = NSTextField(labelWithString: r.item.combo)
        combo.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        combo.textColor = r.item.hasShortcut ? .secondaryLabelColor : .quaternaryLabelColor
        combo.alignment = .right
        combo.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keys.addArrangedSubview(combo)

        if let win = r.windowsEquivalent {
            let winLabel = NSTextField(labelWithString: "Windows: \(win)")
            winLabel.font = .systemFont(ofSize: 10)
            winLabel.textColor = .tertiaryLabelColor
            winLabel.alignment = .right
            winLabel.lineBreakMode = .byTruncatingTail
            winLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            keys.addArrangedSubview(winLabel)
        }

        // 标题占左侧、键位列钉在右侧：两行（⌘S / Windows: Ctrl+S）在右列右对齐，
        // 读起来是一个「键位列」，而不是跟着标题文字长度漂移。
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addView(title, in: .leading)
        cell.addView(keys, in: .trailing)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < filtered.count else { return 26 }
        let r = filtered[row]
        if r.isHeader { return 30 }
        // 有 Windows 第二行的行加高，避免第二行被裁掉或压到相邻行。
        return r.windowsEquivalent == nil ? 26 : 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(row < filtered.count && filtered[row].isHeader)
    }
}

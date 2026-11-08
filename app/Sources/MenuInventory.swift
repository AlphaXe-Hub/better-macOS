import AppKit
import ApplicationServices

// MARK: - 修饰键

/// AX 的 `kAXMenuItemCmdModifiers` 是 Carbon 位掩码，且 **⌘ 隐含**：
/// `0` 表示「⌘」，`8`（bit3）才表示「没有 ⌘」。忘记这一点会把所有快捷键读错，
/// 而且错得「看起来几乎对」。这个类型是唯一允许知道该细节的地方。
struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    static let option  = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    /// Carbon 位掩码 → 语义修饰键。**这是全项目唯一做这件事的地方。**
    static func fromCarbon(_ raw: Int) -> ShortcutModifiers {
        var m: ShortcutModifiers = []
        if raw & 8 == 0 { m.insert(.command) }   // bit3 置位 = 无 ⌘
        if raw & 1 != 0 { m.insert(.shift) }
        if raw & 2 != 0 { m.insert(.option) }
        if raw & 4 != 0 { m.insert(.control) }
        return m
    }

    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

// MARK: - 快捷键条目

/// 一个菜单项。`windowsEquivalent` 是 v1 留的空钩子：
/// 数据结构先付地基，v2 填数据时不用改架构。
struct ShortcutItem {
    let title: String
    let menuGroup: String
    let key: String
    let modifiers: ShortcutModifiers
    let enabled: Bool
    var windowsEquivalent: String? = nil

    var combo: String { modifiers.symbols + key }
    var hasShortcut: Bool { !key.isEmpty }
}

// MARK: - 前台 App 的菜单快照

/// 深模块：调用方只问「这个 App 有哪些快捷键」，不需要知道
/// AX 遍历、超时、Carbon 位掩码、虚键码映射中的任何一件事。
final class MenuInventory {

    struct Snapshot {
        let appName: String
        let pid: pid_t
        let items: [ShortcutItem]
        var withShortcuts: [ShortcutItem] { items.filter(\.hasShortcut) }
        var groups: [String] {
            var seen: [String] = []
            for i in items where !seen.contains(i.menuGroup) { seen.append(i.menuGroup) }
            return seen
        }
    }

    enum Failure: Error {
        case noPermission        // -25211 apiDisabled
        case cannotComplete      // -25204：App 太慢，或没授权时也会出现（实测坑）
        case appGone             // -25202 invalidUIElement
        case noMenuBar           // 成功但拿不到 menuBar（LSUIElement 后台 App）
        case other(Int)
    }

    /// 读取失败时返回失败原因——调用方必须能区分
    /// 「这个 App 没有快捷键」和「我们没有权限 / 读不到」。
    func snapshot(pid: pid_t, appName: String) -> Result<Snapshot, Failure> {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)

        var mbRef: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef)

        // -25204 在未授权时也会出现（不是只有 -25211），且 App 忙时也会。
        // 宽限一次重试，把「慢」和「没权限」尽量分开。
        if err == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.15)
            err = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef)
        }

        switch err {
        case .success:
            guard let mb = mbRef else { return .failure(.noMenuBar) }
            return .success(build(mb as! AXUIElement, pid: pid, appName: appName))
        case .apiDisabled:   return .failure(.noPermission)
        case .cannotComplete: return .failure(.cannotComplete)
        case .invalidUIElement: return .failure(.appGone)
        default: return .failure(.other(Int(err.rawValue)))
        }
    }

    private func build(_ menuBar: AXUIElement, pid: pid_t, appName: String) -> Snapshot {
        var items: [ShortcutItem] = []
        for barItem in children(of: menuBar) {
            let group = string(barItem, kAXTitleAttribute as String)
            walk(barItem, group: group, depth: 0, into: &items)
        }
        return Snapshot(appName: appName, pid: pid, items: items)
    }

    private func walk(_ el: AXUIElement, group: String, depth: Int, into out: inout [ShortcutItem]) {
        guard depth < 6 else { return }
        for child in children(of: el) {
            let role = string(child, kAXRoleAttribute as String)
            if role == "AXMenuItem" {
                if let item = makeItem(child, group: group) { out.append(item) }
            } else if role == "AXMenu" || role == "AXMenuBarItem" || role == "AXMenuItem" {
                walk(child, group: group, depth: depth + 1, into: &out)
            }
        }
    }

    private func makeItem(_ el: AXUIElement, group: String) -> ShortcutItem? {
        let title = string(el, kAXTitleAttribute as String)
        guard !title.isEmpty else { return nil }

        let cmdChar = string(el, kAXMenuItemCmdCharAttribute as String)
        let virtualKey = int(el, kAXMenuItemCmdVirtualKeyAttribute as String)
        let glyph = int(el, kAXMenuItemCmdGlyphAttribute as String)
        let rawMods = int(el, kAXMenuItemCmdModifiersAttribute as String) ?? 0

        let key = ShortcutItemKey.display(cmdChar: cmdChar, virtualKey: virtualKey, glyph: glyph)
        // 没有键位等价物的菜单项（如「显示所有窗口」的纯文字项）也要保留：
        // 面板里可以显示它，只是没有快捷键。
        return ShortcutItem(
            title: title,
            menuGroup: group,
            key: key,
            modifiers: ShortcutModifiers.fromCarbon(rawMods),
            enabled: bool(el, kAXEnabledAttribute as String) ?? true
        )
    }

    // MARK: AX 原语

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    private func children(of el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
    private func string(_ el: AXUIElement, _ n: String) -> String {
        (attr(el, n) as? String) ?? ""
    }
    private func int(_ el: AXUIElement, _ n: String) -> Int? {
        (attr(el, n) as? NSNumber)?.intValue
    }
    private func bool(_ el: AXUIElement, _ n: String) -> Bool? {
        (attr(el, n) as? NSNumber)?.boolValue
    }
}

// MARK: - 虚键码 → 显示字符

enum ShortcutItemKey {
    static func display(cmdChar: String, virtualKey: Int?, glyph: Int?) -> String {
        if !cmdChar.isEmpty { return cmdChar.uppercased() }
        if let vk = virtualKey, let s = virtualKeyMap[vk] { return s }
        if let g = glyph, let s = glyphMap[g] { return s }
        return ""
    }

    /// Carbon 虚拟键码 → 显示字符。
    /// 字母键必须齐全：部分 App 不给 `AXMenuItemCmdChar`，只给虚拟键码，
    /// 缺表会导致「这个快捷键看起来没有键位」。
    static let virtualKeyMap: [Int: String] = [
        // 字母
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // 数字
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        // 标点
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 42: "\\", 50: "`",
        // 特殊键
        36: "⏎", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        76: "⌤", 71: "⌧", 117: "⌦", 115: "↖", 119: "↘",
        116: "↟", 121: "↡", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static let glyphMap: [Int: String] = [
        0x2191: "↑", 0x2193: "↓", 0x2190: "←", 0x2192: "→",
        0x21E7: "⇧", 0x2325: "⌥", 0x2303: "⌃", 0x2318: "⌘",
        0x21A9: "↩", 0x232B: "⌫", 0x2338: "⌦", 0x238B: "⎋",
        0x21E5: "⇥", 0x2423: "Space", 0x21DE: "⇞", 0x21DF: "⇟",
        0x2196: "↖", 0x2198: "↘",
    ]
}

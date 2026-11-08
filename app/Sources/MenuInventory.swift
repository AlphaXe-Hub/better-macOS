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

    /// fn / Globe 键（issue #11 第 ① 层）。
    ///
    /// **它不在 Carbon 位掩码里**：`kAXMenuItemCmdModifiers` 只有
    /// shift(1) / option(2) / control(4) / noCommand(8) 四位（SDK
    /// `AXAttributeConstants.h` 的 `AXMenuItemModifiers`），没有 fn。
    /// 所以 `fromCarbon()` **永远不产出这一位**——从菜单里读到的快捷键不会有 fn，
    /// 这一位只可能由 `KeyStroke.from(event:)` 从真实按键里读出来。
    /// 也正因为如此，加它不会动到那 6 项位掩码测试。
    ///
    /// 选 `1 << 4` 而不是复用某个 Carbon 位：`rawValue` 在前八位里必须和
    /// `fromCarbon()` 的语义一一对应，插进中间会让所有既有位错位。
    static let function = ShortcutModifiers(rawValue: 1 << 4)

    /// Carbon 位掩码 → 语义修饰键。**这是全项目唯一做这件事的地方。**
    static func fromCarbon(_ raw: Int) -> ShortcutModifiers {
        var m: ShortcutModifiers = []
        if raw & 8 == 0 { m.insert(.command) }   // bit3 置位 = 无 ⌘
        if raw & 1 != 0 { m.insert(.shift) }
        if raw & 2 != 0 { m.insert(.option) }
        if raw & 4 != 0 { m.insert(.control) }
        return m
    }

    /// 显示用符号串。顺序是产品里所有组合字符串的**唯一来源**，
    /// 手写数据（WindowsEquivalents 表）必须照着它写，否则「看起来一样、永远匹配不上」。
    ///
    /// fn 排在最前（`fn⌃←`）：macOS 菜单和 Apple 官方快捷键文档都这么写
    /// （例如 Apple《Mac window tiling icons & keyboard shortcuts》里的
    /// "Fn-Control-Left Arrow"）。它不是 ⌃⌥⇧⌘ 那种「动作修饰键」，而是先改变
    /// 这个键本身的含义，所以必须在最里层、最先出现。
    var symbols: String {
        var s = ""
        if contains(.function) { s += "fn" }
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

    /// `Equatable` 是为了让「错误码 → 语义」这个映射能被单测精确断言。
    enum Failure: Error, Equatable {
        case noPermission        // -25211 apiDisabled
        /// -25204，且**耗时≈messaging timeout**：App 真的忙/无响应。
        /// 不重试——每次尝试都要再等满 timeout（见 `shouldRetryTimedOut`）。
        ///
        /// 名字保留 `cannotComplete`（= 错误码本名），但**语义已收窄**：
        /// 只代表「真等到超时了」。同样是 -25204、但 0.1ms 就返回的那种，
        /// 归到下面的 `menuBarNotReady`。
        case cannotComplete
        /// -25204，但**0.1ms 就返回**：App 还没建立菜单栏（冷启动中）、
        /// 或这个进程根本不是 App（crashpad_handler 这类）。
        /// 实测：飞书冷启动后 0.3~4.7s 内每次都走这条，之后永久成功。
        /// 把它当「超时」去重试是错的——重试再多次也不会变，得**等**。
        case menuBarNotReady
        case appGone             // -25202 invalidUIElement
        /// 这个进程**本来就没有菜单栏**（后台服务、菜单栏小组件、登录窗口等）。
        /// -25212 noValue 和 -25208 notImplemented 都归到这里。
        /// 这**不是错误**，是正常情况——把它当错误报给用户是错的。
        case noMenuBar
        case other(Int)

        /// 是否是"这个 App 就是没有菜单"这类正常情况（不该弹报错）。
        var isExpectedNoMenu: Bool {
            switch self {
            case .noMenuBar, .menuBarNotReady: return true
            default: return false
            }
        }

        /// 是否是**暂时性**失败（稍后可能自己变好）。
        ///
        /// 注意：这只是必要条件，不是重试的充分条件——
        /// `cannotComplete` 是暂时性的，但因为它每次都要等满 timeout，
        /// 实际策略里**不重试**（见 `MenuInventory.shouldRetryTimedOut`）。
        var isTransient: Bool {
            switch self {
            case .cannotComplete, .menuBarNotReady: return true
            default: return false
            }
        }
    }

    // MARK: 超时策略

    /// 单个 AX 对象的消息超时。
    static let messagingTimeout: Float = 2.0

    /// 进程级全局超时。**必须设**，理由见 `installGlobalTimeout()`。
    static let globalTimeout: Float = 1.0

    /// -25204 的「超时指纹」判定阈值：耗时达到 timeout 的这个比例才算真超时。
    /// 实测真超时的耗时是 timeout 的 100.0%~100.3%，而冷启动的快速失败是 0.1~0.3ms，
    /// 两者差了三个数量级，0.5 这个阈值有巨大余量。
    static let timeoutFingerprintRatio: Double = 0.5

    /// 冷启动 App 的补偿重试退避：0.15 / 0.3 / 0.6 / 1.0 秒（累计约 2.05s）。
    ///
    /// **只对 `menuBarNotReady` 且确实是 GUI App 的情况用**。
    /// 每次尝试只要 0.2ms，重试几乎不花成本。
    /// 实测飞书冷启动的不可读窗口：0.01s / 0.36s / 0.38s / **4.7s**（首次初始化时）。
    /// 2s 预算覆盖前三者；4.7s 那种极端情况留给调用方的下一次前台切换补读——
    /// 在后台队列里死等 5 秒，用户看到的是「切过去半天没反应」，比读到旧数据更糟。
    static let readyRetryBackoff: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]

    /// `menuBarNotReady` 是否可能是「App 正在冷启动」。
    ///
    /// 实测（2026-11-08，微信 4.1）同一个 `-25204` 来自两类完全不同的进程：
    ///   - 冷启动中的 GUI App：`NSRunningApplication` **存在**（微信主进程 pid 91969）
    ///   - 根本不是 GUI App 的辅助进程：`NSRunningApplication` 为 **nil**
    ///     （crashpad_handler pid 91971、WeChatHelper pid 92019 —— 都 0.1ms 返回 -25204）
    ///
    /// 这个区分很值钱：对前者重试是**等它好**（有收益）；
    /// 对后者重试是**白等 2 秒**（实测旧版 165ms 出结果，不区分就变成 2069ms）。
    /// 后台进程没有菜单栏是**正常情况**，不该让用户为它等两秒。
    static func couldBeStartingUp(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    /// `cannotComplete`（真超时）**不重试**。
    ///
    /// 反直觉但实测必须如此：每次尝试都要实打实等满 timeout。
    /// 早先版本对它重试 4 次，实测（SIGSTOP 卡死微信）总耗时 **8886ms**——
    /// 比修复前的 2000ms 还糟 4 倍。App 真忙的时候，多试几次大概率还是忙。
    static let shouldRetryTimedOut = false

    private static var didInstallGlobalTimeout = false

    /// `AXUIElementSetMessagingTimeout` **只对设过的那个对象生效，不向子元素继承**。
    /// 实测（2026-11-08，微信 pid 91969，SIGSTOP 模拟卡死）：
    ///   - appEl 设 0.5s 后，子元素读标题仍各花 **1500ms**（全局默认 1.5s）
    ///   - 改用 `AXUIElementCreateSystemWide()` 设 0.5s 后，子元素变成 **503ms**
    /// 不设的话，App 在「读到菜单栏之后、遍历还没结束」时卡住，
    /// 就要按 1.5s × 菜单项数量 累加——200 项的 App 能把后台队列钉死 5 分钟。
    private static func installGlobalTimeout() {
        guard !didInstallGlobalTimeout else { return }
        didInstallGlobalTimeout = true
        // 只影响本进程，不影响别的 App
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), globalTimeout)
    }

    /// 把一次读取的 (err, 耗时) 翻译成语义。**纯函数，可单测。**
    ///
    /// 这是这次修复的核心：`-25204` 一个错误码背了两个完全不同的含义。
    static func classify(_ err: AXError, elapsed: TimeInterval, timeout: Float) -> Failure? {
        switch err {
        case .success:            return nil
        case .apiDisabled:        return .noPermission
        case .invalidUIElement:   return .appGone
        case .noValue, .notImplemented, .attributeUnsupported:
            return .noMenuBar
        case .cannotComplete:
            // 真等到超时了 → App 忙；几乎立刻返回 → 菜单栏还没建好（冷启动）或根本不是 App。
            let threshold = Double(timeout) * timeoutFingerprintRatio
            return elapsed >= threshold ? .cannotComplete : .menuBarNotReady
        default:                  return .other(Int(err.rawValue))
        }
    }

    /// 读取失败时返回失败原因——调用方必须能区分
    /// 「这个 App 没有快捷键」和「我们没有权限 / 读不到」。
    func snapshot(pid: pid_t, appName: String) -> Result<Snapshot, Failure> {
        Self.installGlobalTimeout()

        var lastFailure: Failure = .other(0)
        for attempt in 0 ... Self.readyRetryBackoff.count {
            let (result, failure) = read(pid: pid, appName: appName)
            if let result { return result }
            lastFailure = failure!

            // 重试只对「便宜且会自己好」的失败有意义：
            //   - menuBarNotReady：0.2ms 就返回，冷启动中的 App 随时可能就绪 → 值得重试
            //   - cannotComplete：每次都要等满 timeout，重试 = 成倍拖延 → 不重试
            //   - noMenuBar / noPermission：再试也不会变 → 不重试
            let retryable: Bool = {
                switch lastFailure {
                case .menuBarNotReady: return Self.couldBeStartingUp(pid: pid)
                case .cannotComplete:  return Self.shouldRetryTimedOut
                default:               return false
                }
            }()
            guard retryable, attempt < Self.readyRetryBackoff.count else { break }
            Thread.sleep(forTimeInterval: Self.readyRetryBackoff[attempt])
        }
        return .failure(lastFailure)
    }

    private func read(pid: pid_t, appName: String) -> (Result<Snapshot, Failure>?, Failure?) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, Self.messagingTimeout)

        var mbRef: CFTypeRef?
        let t0 = DispatchTime.now().uptimeNanoseconds
        let err = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000

        if let failure = Self.classify(err, elapsed: elapsed, timeout: Self.messagingTimeout) {
            return (nil, failure)
        }
        guard let mb = mbRef else { return (nil, .noMenuBar) }
        return (.success(build(mb as! AXUIElement, pid: pid, appName: appName)), nil)
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

    /// **按住 fn 时，同一个物理方向键会报另一个键码。**
    ///
    /// | 物理键 | 不按 fn | 按住 fn | 键码原义（不按 fn 时确实该这么显示） |
    /// |---|---|---|---|
    /// | ← | 123 | **115** | ↖ Home |
    /// | → | 124 | **119** | ↘ End |
    /// | ↑ | 126 | **116** | ↟ PageUp |
    /// | ↓ | 125 | **121** | ↡ PageDown |
    ///
    /// 键码本义是对的：**裸按 115 就是 Home**，所以 `virtualKeyMap` 里 115 → ↖
    /// 不能改。错的只是「按住 fn 时还这么说」——那一刻它不是 Home，是 fn+←。
    ///
    /// 不要试图从 `charactersIgnoringModifiers` 反推：按住 fn 时它也是私用区码位
    /// （`NSHomeFunctionKey` 0xF729），给不出方向。真值只有一张表：这个字典。
    static let fnRemappedKeyCodes: [Int: String] = [
        115: "←", 119: "→", 116: "↑", 121: "↓",
    ]

    /// 真键盘事件的键 → 显示字符。**纯函数，全项目唯一一处做「fn 改键码」翻译。**
    ///
    /// 为什么必须是纯函数：真键盘事件在单测里造不出来（`fn` 的按住状态只存在于
    /// `CGEvent` 的 `.maskSecondaryFn`，`NSEvent.keyEvent(...)` 合成出来的事件
    /// 拿不到那个位），所以这层语义只能靠「喂事实、断结果」来守住。
    ///
    /// ## 它修的是什么 bug（用户报的「fn+方向键没反应」）
    ///
    /// 用户按 fn⌃←，系统投递的是 keyCode **115**，查 `virtualKeyMap` 得到 `↖`，
    /// 于是组合成了 `fn⌃↖`。而 `SystemShortcuts` 表按 Apple 官方写法登记的是
    /// `fn⌃←` —— 一个 `↖` 对不上一个 `←`，**查表永远失败**，静默丢弃。
    /// 换算后组合还原成 `fn⌃←`，表命中了，用户才看得到「平铺到左半屏」。
    ///
    /// 只对**按住 fn 时**生效：裸 Home 键（115）仍然显示 ↖，那是它的真名。
    /// 顺带一提，键盘右上角那颗写着「home」的键报的也是 115 —— 所以不能
    /// 「把 115 一律改成 ←」，那会把这颗真 Home 键也叫成 fn←。fn 才是区分依据。
    static func displayKey(cmdChar: String, virtualKey: Int?, fnHeld: Bool) -> String {
        if let vk = virtualKey {
            if fnHeld, let arrow = fnRemappedKeyCodes[vk] { return arrow }
            if let mapped = virtualKeyMap[vk] { return mapped }
        }
        return cmdChar.isEmpty ? "" : cmdChar.uppercased()
    }

    static let glyphMap: [Int: String] = [
        0x2191: "↑", 0x2193: "↓", 0x2190: "←", 0x2192: "→",
        0x21E7: "⇧", 0x2325: "⌥", 0x2303: "⌃", 0x2318: "⌘",
        0x21A9: "↩", 0x232B: "⌫", 0x2338: "⌦", 0x238B: "⎋",
        0x21E5: "⇥", 0x2423: "Space", 0x21DE: "⇞", 0x21DF: "⇟",
        0x2196: "↖", 0x2198: "↘",
    ]
}

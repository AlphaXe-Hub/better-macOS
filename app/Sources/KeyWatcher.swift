import AppKit
import ApplicationServices

// MARK: - 一次按键

struct KeyStroke: Equatable {
    let key: String                    // "S" / "⏎" / "→"
    let modifiers: ShortcutModifiers

    var combo: String { modifiers.symbols + key }

    /// 从 NSEvent 解码。**注意**：`addGlobalMonitorForEvents` 需要的是
    /// Accessibility 权限（不是 Input Monitoring）——Apple 文档明写
    /// "Key-related events may only be monitored if accessibility is enabled"。
    /// 这意味着整个 App 只需要一个权限开关。
    static func from(event: NSEvent) -> KeyStroke? {
        var mods: ShortcutModifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.shift)   { mods.insert(.shift) }
        if f.contains(.option)  { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if fnIsHeld(event)      { mods.insert(.function) }   // issue #11 第 ① 层

        let key = displayKey(for: event)
        guard !key.isEmpty else { return nil }
        return KeyStroke(key: key, modifiers: mods)
    }

    // MARK: fn —— 全项目唯一知道「怎么判断 fn 被按住」的地方

    /// fn 是否真的被按住。**这不是 `modifierFlags.contains(.function)` 一句话的事。**
    ///
    /// ## 为什么不能用语义位（实测，2026-11-08，macOS 26.5 / arm64）
    ///
    /// AppKit 给 `NSEventModifierFlagFunction`（1 << 23）写的注释是
    /// 「Set if any function key is pressed」——它说的是**这个键本身是不是功能键**，
    /// 不是「fn 键被按住了」。两者在方向键 / F 键 / Home 等键上**恰好相反**的直觉：
    ///
    /// | 实际按的键 | `modifierFlags.contains(.function)` | `cgEvent.flags.contains(.maskSecondaryFn)` |
    /// |---|---|---|
    /// | 裸 ←（123）        | **true** | **false** |
    /// | fn + ←（123）      | true     | **true**  |
    /// | 裸 ↑（126）        | **true** | **false** |
    /// | 裸 F5（96）        | **true** | **false** |
    /// | 裸 A（0）          | false    | false     |
    /// | fn + A（0）        | true     | **true**  |
    ///
    /// 也就是说：照 issue #11 原文的写法（`if f.contains(.function)`）会让**每一个
    /// 裸方向键**都被标成 `fn←`——那不是修复误报，而是把误报换了个方向。
    /// 真实的 fn 状态只存在于 `CGEvent` 的 `.maskSecondaryFn`
    /// （`kCGEventFlagMaskSecondaryFn` = `NX_SECONDARYFNMASK` = 0x00800000，
    /// 见 SDK `CGEventTypes.h` / `IOLLEvent.h`）。
    ///
    /// 同一张表也解释了为什么 `KeyStroke.from()` **不读** `.capsLock` 之外的
    /// device-dependent 位：`NSEventModifierFlagDeviceIndependentFlagsMask` 之外的东西
    /// 不是「用户按住的状态」，混进来就会产生假的组合。
    ///
    /// ## 兜底
    ///
    /// `event.cgEvent` 理论上总是有值，但它是一个**可能为 nil 的桥接**：拿不到时
    /// 只能退回语义位，而语义位对功能键类恒为 true。这种情况下**宁可不标 fn**：
    /// 漏报一个 fn 只是少显示两个字符，误报会让人去按一个不该按的组合。
    static func fnIsHeld(_ event: NSEvent) -> Bool {
        fnIsHeld(cgSecondaryFn: event.cgEvent?.flags.contains(.maskSecondaryFn),
                 nsFunctionBit: event.modifierFlags.contains(.function),
                 isFunctionKey: isFunctionKeyScan(event))
    }

    /// 纯函数版本，给单测用（真键盘事件造不出来，只能喂这三条事实）。
    ///
    /// 三个入参就是判断 fn 所需的**全部**信息，逻辑一点也不外泄到调用方。
    static func fnIsHeld(cgSecondaryFn: Bool?, nsFunctionBit: Bool, isFunctionKey: Bool) -> Bool {
        if let cgSecondaryFn { return cgSecondaryFn }
        return nsFunctionBit && !isFunctionKey
    }

    /// 这个键是不是「功能键类」（方向键、F 键、Home/End/PageUp…）。
    /// 判据：AppKit 把这些键的 `charactersIgnoringModifiers` 放在私用区
    /// `NSUpArrowFunctionKey`(0xF700) … 0xF8FF（SDK `NSEvent.h`）。
    static func isFunctionKeyScan(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers else { return false }
        return chars.unicodeScalars.contains { $0.value >= 0xF700 && $0.value <= 0xF8FF }
    }

    /// 虚拟键码就是 Carbon virtual key code，和 AX 的 `AXMenuItemCmdVirtualKey` 同域，
    /// 所以两侧可以共用同一张表——这是能让「按下的键」和「菜单里的键」对上的关键。
    static func displayKey(for event: NSEvent) -> String {
        if let mapped = ShortcutItemKey.virtualKeyMap[Int(event.keyCode)] { return mapped }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return ""
    }
}

// MARK: - 键盘观察

/// 深模块：调用方只订阅「用户按了哪一组键」，
/// 不需要知道全局 monitor 的安装、修饰键跟踪、自身事件过滤。
///
/// **为什么不用 AXMenuItemSelected**：本机实测（自读场景，无需授权）
/// 该通知在 menuBar 和 App 上注册都返回 0，但真实触发菜单项后 **0 条通知**。
/// 跨 App 场景无法在无授权条件下验证，不能把它作为产品主数据源。
/// 而按键监听 + 菜单树反查这条路，其依赖（Accessibility）和 AX 读取是同一个权限，
/// 且行为可预测、可测试。
final class KeyWatcher {

    var onKeyDown: ((KeyStroke) -> Void)?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private(set) var isRunning = false

    /// 装监听器。**可以被重复调用**——授权可能在 start() 之后才生效，
    /// 那时第一次装的 monitor 是无效的（能装、但零投递），必须能重装。
    func start() {
        stop()
        let trusted = AXIsProcessTrusted()

        // keyDown：主体的快捷键识别
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let stroke = KeyStroke.from(event: event) else { return }
            Diag.log("RAWKEY \(stroke.combo)")
            self.onKeyDown?(stroke)
        }

        // flagsChanged：单独用来感知「只按住 ⌘」这种状态（面板唤起、修饰键提示）
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            self?.lastFlagsChange = ProcessInfo.processInfo.systemUptime
        }

        isRunning = true
        Diag.log("KEYWATCHER started trusted=\(trusted) keyMonitor=\(keyMonitor != nil ? "ok" : "NIL")")
        // 实测：直接执行二进制时 AXIsProcessTrusted() 会"继承"终端的授权而返回 true，
        // 只有经 LaunchServices（open / Finder / Dock）启动才是真实状态。
        // 所以这个值只能用来判断"用户是否真的授权"，不能用来判断"我的代码对不对"。
        if !trusted {
            Diag.log("  ⚠️ 未授权：吐司与快捷键面板都不会工作")
        }
    }

    private(set) var lastFlagsChange: TimeInterval = 0

    func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        flagsMonitor = nil
        isRunning = false
    }
}

// MARK: - 按键 → 动作名

/// 深模块：给它「前台 App 的菜单快照」和「用户按下的键」，
/// 它回答「这组键对应哪个动作」。调用方不需要知道匹配规则。
///
/// 这是产品语义的核心：**我们同时知道「按了什么键」和「触发了什么动作」**，
/// 而只观察菜单的实现只能知道后者。
final class ShortcutResolver {

    /// 匹配结果。`action == nil` 表示这个键在当前 App 里没有绑定任何菜单项。
    struct Resolution {
        let stroke: KeyStroke
        let action: String?
        let menuGroup: String?
        let appName: String

        var isUnknown: Bool { action == nil }
    }

    func resolve(stroke: KeyStroke, in snapshot: MenuInventory.Snapshot?) -> Resolution {
        guard let snapshot else {
            return Resolution(stroke: stroke, action: nil, menuGroup: nil, appName: "")
        }
        let hit = snapshot.items.first { item in
            item.key == stroke.key && item.modifiers == stroke.modifiers
        }
        return Resolution(stroke: stroke,
                          action: hit?.title,
                          menuGroup: hit?.menuGroup,
                          appName: snapshot.appName)
    }
}

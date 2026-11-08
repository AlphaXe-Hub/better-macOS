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

        let key = displayKey(for: event)
        guard !key.isEmpty else { return nil }
        return KeyStroke(key: key, modifiers: mods)
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

    func start() {
        guard keyMonitor == nil else { return }

        // keyDown：主体的快捷键识别
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let stroke = KeyStroke.from(event: event) else { return }
            // 纯修饰键组合（只按 ⌘）由 flagsChanged 处理，这里只收有主键的
            self.onKeyDown?(stroke)
        }

        // flagsChanged：单独用来感知「只按住 ⌘」这种状态（面板唤起、修饰键提示）
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            self?.lastFlagsChange = ProcessInfo.processInfo.systemUptime
        }

        isRunning = true
        NSLog("[better-macOS] key watcher started (AXtrusted=%@)", "\(AXIsProcessTrusted())")
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

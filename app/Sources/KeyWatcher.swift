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

        // fn 只算一次：它既是「组合里的一位」，又决定「这个键码该叫什么名字」。
        // 两处各算一次就会出现「组合带 fn、键名却不带」的自相矛盾状态。
        let fn = fnIsHeld(event)                            // issue #11 第 ① 层
        if fn { mods.insert(.function) }

        let key = displayKey(for: event, fnHeld: fn)
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
    ///
    /// **但两侧对「同一个键码叫什么」并不总是一致**：按住 fn 时方向键会换一个键码
    /// （← 从 123 变成 115），而菜单里永远登记 Apple 官方写法 `fn⌃←`。
    /// 翻译逻辑在 `ShortcutItemKey.displayKey(cmdChar:virtualKey:fnHeld:)`，
    /// 这里是它的唯一调用方，`fnHeld` 必须传真的那个值。
    static func displayKey(for event: NSEvent, fnHeld: Bool) -> String {
        ShortcutItemKey.displayKey(cmdChar: event.charactersIgnoringModifiers ?? "",
                                   virtualKey: Int(event.keyCode),
                                   fnHeld: fnHeld)
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

// MARK: - 系统级快捷键清单（issue #11 第 ②④ 层）

/// macOS 自己处理的快捷键。**这不是「我们收不到」的清单，也不是「猜」的清单。**
///
/// ## 它到底解决什么问题
///
/// 用户按下一个键、屏幕没反应，原因有三类，而**只有一类是真 bug**：
/// 1. 我们漏读了修饰键 → 真 bug（第 ① 层，已修，见 `KeyStroke.fnIsHeld`）
/// 2. 这个键被 macOS 在 App 之前吃掉 → 不是 bug，是设计边界
/// 3. 这个 App 的菜单里本来就没有这个键位 → 不是 bug，是数据源边界
///
/// 第 2、3 类在代码里长得一模一样（`action == nil`）。不给用户解释，他只会认为
/// 「工具坏了」——这正是 issue 的抱怨。所以这里维护一张**有出处**的系统快捷键表，
/// 让吐司和设置页能说清「这个键是什么、为什么查不到动作名」。
///
/// ## 判据与「不瞎猜」的边界
///
/// 判定方式是**精确命中这张表**，不做任何修饰键启发式（例如「⌃+方向键就当系统级」）。
/// 理由：启发式会把 App 自己绑的 ⌃↑ 误标成「系统级」，那和误报动作名是**同一类错误**
/// ——用户会去系统设置里找，然后更困惑。表里没有的，就只说「这个 App 没有绑定」。
///
/// 表里的每一条都是 Apple 文档明写的系统快捷键，且**不包含**任何
/// 「由当前 App 处理」的键——最典型的是 `fn← / fn→ / fn↑ / fn↓`：
/// Apple 把它们列在 *Text-editing shortcuts*（Home / End / Page Up / Page Down，
/// 由焦点所在的 App 处理），不是系统快捷键。把它们塞进这张表，
/// 用户在文本编辑器里按 fn← 就会被错误告知「系统级」。
///
/// ## 出处（逐条核对，2026-11-08）
///
/// - [A1] Apple《Mac keyboard shortcuts》https://support.apple.com/en-us/102650
///   ⌃↑ 调度中心、⌃↓ 前台 App 的所有窗口、⌃←/⌃→ 切换桌面、⌘Space、
///   ⌃⌘Space、⇧⌘3/4/5、⌘⇥、⌘`、⌃⌘F、⌃Space（切换输入源）、
///   Fn-A/C/D/N/H/F11、Fn-Shift-A
/// - [A2] Apple《Mac window tiling icons & keyboard shortcuts》
///   https://support.apple.com/guide/mac-help/mchl9674d0b0/mac
///   Fn-Control-F/C/R、Fn-Control-Left/Right/Up/Down Arrow、
///   Fn-Control-Shift-Arrow、Fn-Control-Option-Shift-Arrow（macOS 15 Sequoia 起）
/// - [A3] Apple《Work in multiple spaces on Mac》
///   https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac
///   「Press the Control key and the Right or Left arrow key.」
///
/// ## 覆盖范围（如实说）
///
/// 这张表**不完整，也不打算完整**：`AppleSymbolicHotKeys` 里有几十项，ID 没有官方
/// 对照表、默认项常常不落盘（见 research/tech-feasibility.md §2.4）。
/// 收进来的都是「高频 + 官方文档明确 + 与迁移者肌肉记忆相关」的条目。
/// 没收录的系统快捷键会退回「这个 App 没有绑定」——**少说一句，不说错一句**。
enum SystemShortcuts {

    struct Entry: Equatable {
        /// 产品统一写法：`ShortcutModifiers.symbols + key`，即 `fn⌃⌥⇧⌘` + 键。
        /// **手写时必须照着这个顺序**，否则用户按出来的组合永远匹配不上。
        let combo: String
        /// 这个键在 macOS 上的动作（中文，按 Apple 中文文档的说法）。
        let name: String
        /// 设置页分组用。
        let group: String
        /// 出处标记，测试会断言它非空（没有出处 = 拍脑袋，不许进表）。
        let source: String
        /// 适用版本。**nil 表示「所有受支持的版本都一样」**，不是「没查」。
        ///
        /// 存在的理由：窗口平铺是 macOS 15 Sequoia 才有的。在 Sonoma 上把
        /// fn⌃← 说成「平铺到左半屏」就是一句谎话 —— 而 App 的
        /// `LSMinimumSystemVersion` 是 14.0，真有用户跑在 Sonoma 上。
        /// 版本信息本来只写在源注释里，注释进不了吐司，所以它得是数据。
        var versions: String? = nil
    }

    /// 精确查表。查不到返回 nil —— **绝不猜**。
    static func lookup(combo: String) -> Entry? {
        all.first { $0.combo == combo }
    }

    /// 设置页要按组展示，这里保持表里的顺序（先桌面空间，再窗口，再系统界面）。
    static func grouped() -> [(group: String, entries: [Entry])] {
        var order: [String] = []
        for e in all where !order.contains(e.group) { order.append(e.group) }
        return order.map { g in (g, all.filter { $0.group == g }) }
    }

    /// 所有组合都必须能被产品自己的解析器还原成同样的语义
    /// （测试会用它守住「手写数据与 symbols 顺序一致」）。
    static func parse(_ combo: String) -> (modifiers: ShortcutModifiers, key: String)? {
        var mods: ShortcutModifiers = []
        var rest = Substring(combo)
        while let head = rest.first {
            if rest.hasPrefix("fn") { mods.insert(.function); rest = rest.dropFirst(2); continue }
            switch head {
            case "⌃": mods.insert(.control)
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            case "⌘": mods.insert(.command)
            default:  return rest.isEmpty ? nil : (mods, String(rest))
            }
            rest = rest.dropFirst()
        }
        return nil   // 只有修饰键、没有键位
    }

    // MARK: 表

    static let all: [Entry] = [
        // —— 桌面与空间（[A1] / [A3]）——
        Entry(combo: "⌃↑", name: "调度中心", group: "桌面与空间", source: "A1"),
        Entry(combo: "⌃↓", name: "前台 App 的所有窗口", group: "桌面与空间", source: "A1"),
        Entry(combo: "⌃←", name: "向左切换一个桌面", group: "桌面与空间", source: "A1/A3"),
        Entry(combo: "⌃→", name: "向右切换一个桌面", group: "桌面与空间", source: "A1/A3"),

        // —— 窗口平铺：整组都要带 fn，这是迁移者最常踩的一组（[A2]）——
        Entry(combo: "fn⌃←", name: "平铺到左半屏", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃→", name: "平铺到右半屏", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃↑", name: "平铺到上半屏", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃↓", name: "平铺到下半屏", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃⇧←", name: "左右分屏（左）", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃⇧→", name: "左右分屏（右）", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃⌥⇧←", name: "左侧 + 右侧四分", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃⌥⇧→", name: "右侧 + 左侧四分", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃F", name: "铺满桌面", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃C", name: "窗口居中", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "fn⌃R", name: "恢复平铺前的大小", group: "窗口", source: "A2", versions: "macOS 15 起"),
        Entry(combo: "⌃⌘F", name: "进入 / 退出全屏", group: "窗口", source: "A1"),

        // —— 系统界面（[A1]）——
        Entry(combo: "⌘Space", name: "聚焦搜索（Spotlight）", group: "系统界面", source: "A1"),
        Entry(combo: "⌃⌘Space", name: "字符检视器（表情与符号）", group: "系统界面", source: "A1"),
        Entry(combo: "⌘⇥", name: "切换 App", group: "系统界面", source: "A1"),
        Entry(combo: "⌘`", name: "切换同一 App 的窗口", group: "系统界面", source: "A1"),
        Entry(combo: "⌃Space", name: "切换输入源", group: "系统界面", source: "A1"),
        Entry(combo: "fnA", name: "显示 / 隐藏程序坞", group: "系统界面", source: "A1"),
        Entry(combo: "fnC", name: "显示 / 隐藏控制中心", group: "系统界面", source: "A1"),
        Entry(combo: "fnN", name: "显示 / 隐藏通知中心", group: "系统界面", source: "A1"),
        Entry(combo: "fnD", name: "开始 / 停止听写", group: "系统界面", source: "A1"),
        Entry(combo: "fnH", name: "显示桌面", group: "系统界面", source: "A1"),
        Entry(combo: "fnF11", name: "显示桌面", group: "系统界面", source: "A1"),
        Entry(combo: "fn⇧A", name: "显示 App（启动台）", group: "系统界面", source: "A1"),

        // —— 截屏（[A1]）——
        Entry(combo: "⇧⌘3", name: "全屏截图", group: "截屏", source: "A1"),
        Entry(combo: "⇧⌘4", name: "区域截图", group: "截屏", source: "A1"),
        Entry(combo: "⇧⌘5", name: "截屏工具栏", group: "截屏", source: "A1"),
    ]
}

// MARK: - 未绑定时对用户说的话

/// `action == nil` 时给用户看的两行字。**纯数据 + 纯函数，可单测。**
///
/// 单独抽出来是因为这段文案本身就是一个产品决定：issue #11 明确要求
/// 「区分两种文案」，而「说了错的理由」和「报错动作名」一样会把人引到错误方向。
struct UnboundCopy: Equatable {
    /// 第一行（大字）。
    let title: String
    /// 第三行（小字解释）。空串表示不显示。
    let note: String
}

// MARK: - 未绑定时「要不要弹」的策略

/// issue #11 第 4 条的另一半：不只是**说什么**，还有**该不该说**。
/// 纯函数放在这里（而不是 AppDelegate），是为了让 `app/test.sh` 能直接断言它——
/// 编排层那 900 行没人想在单测里拖进来。
enum UnboundPolicy {

    /// 每一类的处理刻意不同：
    /// - **系统级**：总是弹。按了 ⌃↑ 没反应，最需要的正是「这是系统键、不是工具坏了」。
    ///   它不会造成打字噪音——系统级组合本来就不会在打字时出现。
    /// - **确实没绑定**：跟随 `hud.show-unknown`（默认关）。这是噪音开关。
    /// - **还读不到菜单**：不弹。我们没有任何确定信息可说，弹出来只会增加困惑。
    ///
    /// - Parameter repeated: 这个组合是不是已经**反复按过好几次**
    ///   （判据在 `UnboundNudge`）。**这是「不再静默」的闸门**：默认关的
    ///   未绑定提示，在用户明显在重复尝试时放行一次。
    ///
    ///   为什么不是直接把 `hud.show-unknown` 默认改成 true：那样用户每打一个
    ///   没绑定的组合都会被弹一次，包括正常输入时手滑按到的 ⌘J 之类 ——
    ///   一个天天在眼前闪的东西会被关掉，然后**连真正有用的那次也不弹了**。
    ///   反复按的关键区别在于：用户的行为已经表达了困惑，此时解释才有价值。
    static func shouldToast(miss: ShortcutResolver.Resolution.Miss?,
                            showUnknown: Bool,
                            repeated: Bool = false) -> Bool {
        switch miss {
        case .systemReserved: return true
        case .notBound:       return showUnknown || repeated
        case .noSnapshot:     return false
        case nil:             return false
        }
    }
}

// MARK: - 「这次该不该多嘴」：反复按的闸门

/// 用户反复按同一个「查不到」的组合时，放开一次解释。
///
/// ## 为什么需要它
///
/// 这次 bug 真正伤人的地方不是「查不到」，而是**查不到 + 永远沉默**。
/// 用户按了某个组合、屏幕上什么都没有，他不知道是「这个键不属于我们」还是
/// 「这个工具坏了」。如果他按了好几次，我们一次都没说话 —— 这正是那次投诉。
///
/// ## 为什么不是「全都弹」
///
/// 未绑定提示的默认值是关，而且必须关着：打字、手滑、编辑器里的临时组合
/// 都会产生未绑定按键。真把它们全弹出来，用户会关掉吐司 —— 那时连
/// 「⌘S = 存储」这种有用的提示也一起没了。所以只在国内**同一个组合
/// 被反复按**时才说一次：那已经是一个人在反复确认「为什么没反应」了。
///
/// ## 纯逻辑 / 纯状态
///
/// 时间和「这个组合按过几次」都由调用方喂进来（`now` / `presses`），
/// 这样单测不需要 sleep、也不需要假时钟。
struct UnboundNudge {

    /// 同一个组合按到第几次才值得开口。取 3：第 1 次可能只是想按别的键，
    /// 第 2 次可能是手滑重复，第 3 次基本可以确定是「我在试这个键」。
    static let threshold = 3

    /// 两次之间隔太久就不算「反复按」了（用户中途去干别的了）。
    static let idleGap: TimeInterval = 4.0

    /// 同一个组合同一轮里最多解释几次。
    ///
    /// 不设上限的话，用户按住不放（`isARepeat` 或手抖连按）会弹出一串一样的吐司，
    /// 那就从「沉默」走到了另一个极端。
    static let maxExplanations = 2

    /// 一个组合的按键计数。值语义，方便单测直接构造。
    struct Presses: Equatable {
        var count: Int
        var explained: Int
        var lastAt: TimeInterval
    }

    /// 记一次按键，返回新的计数。
    ///
    /// 隔了超过 `idleGap` 秒再按，就从 1 重新数 —— 否则一天下来「按过 3 次」
    /// 会随机命中某次无关的按键，弹一句莫名其妙的解释。
    static func record(presses: Presses?, now: TimeInterval) -> Presses {
        guard let old = presses, now - old.lastAt <= idleGap else {
            return Presses(count: 1, explained: presses?.explained ?? 0, lastAt: now)
        }
        return Presses(count: old.count + 1, explained: old.explained, lastAt: now)
    }

    /// 这一次该不该多说一句。**不改状态**——计数由 `record` 负责，这里只判断。
    static func shouldExplain(_ p: Presses?) -> Bool {
        guard let p else { return false }
        return p.count >= threshold && p.explained < maxExplanations
    }

    /// 说过了，记一笔（否则同一个组合会被解释无限多次）。
    static func didExplain(_ p: Presses) -> Presses {
        Presses(count: p.count, explained: p.explained + 1, lastAt: p.lastAt)
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
        /// 为什么没有动作名。**三类的区别是产品要说给用户听的，不能混成一句。**
        let miss: Miss?

        enum Miss: Equatable {
            /// 菜单读到了，但里面确实没有这个键位。
            case notBound
            /// 命中系统级清单：这个键由 macOS 处理，不登记在任何 App 的菜单里。
            case systemReserved(SystemShortcuts.Entry)
            /// 还没读到前台 App 的菜单（无权限 / 冷启动 / 这个进程没有菜单栏）。
            /// **不能归到 notBound**：那会把「我们没看到」说成「它不存在」。
            case noSnapshot
        }

        var isUnknown: Bool { action == nil }

        /// 未绑定时该说的话。`action != nil` 时返回 nil（走正常的动作名吐司）。
        var unboundCopy: UnboundCopy? {
            guard action == nil else { return nil }
            switch miss {
            case .systemReserved(let entry):
                // 「由 macOS 直接处理」有 Apple 文档出处（见 SystemShortcuts）。
                // 刻意不写「我们看不到」：实测这些键有时**能**到达监听器
                // （⌃↑ / ⌃↓ / ⌃← / fn⌃F / fn⌃R / fn⌃C 本机都看到过），
                // 写死「看不到」是另一句会被用户当场证伪的话。
                return UnboundCopy(title: entry.name,
                                   note: "macOS 系统快捷键 —— 由系统直接处理，不在 App 菜单里")
            case .notBound:
                let app = appName.isEmpty ? "这个 App" : "「\(appName)」"
                return UnboundCopy(title: "没有绑定",
                                   note: "\(app)的菜单里没有这个键位")
            case .noSnapshot:
                return UnboundCopy(title: "还读不到菜单",
                                   note: "先切到目标 App 再按一次；若一直如此请检查辅助功能授权")
            case nil:
                return UnboundCopy(title: "没有绑定", note: "")
            }
        }
    }

    func resolve(stroke: KeyStroke, in snapshot: MenuInventory.Snapshot?) -> Resolution {
        // 快照缺失时**不要**假装「这个 App 没绑定」——那是两类完全不同的事实。
        guard let snapshot else {
            return Resolution(stroke: stroke, action: nil, menuGroup: nil, appName: "",
                              miss: .noSnapshot)
        }
        let hit = snapshot.items.first { item in
            item.key == stroke.key && item.modifiers == stroke.modifiers
        }
        if let hit {
            return Resolution(stroke: stroke,
                              action: hit.title,
                              menuGroup: hit.menuGroup,
                              appName: snapshot.appName,
                              miss: nil)
        }
        // 菜单里没有 → 再看是不是系统级。**只精确查表，不做修饰键启发式。**
        let miss: Resolution.Miss
        if let entry = SystemShortcuts.lookup(combo: stroke.combo) {
            miss = .systemReserved(entry)
        } else {
            miss = .notBound
        }
        return Resolution(stroke: stroke,
                          action: nil,
                          menuGroup: nil,
                          appName: snapshot.appName,
                          miss: miss)
    }
}

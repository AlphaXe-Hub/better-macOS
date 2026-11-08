import Foundation

// MARK: - Windows ↔ Mac 键位对照表（issue #4）
//
// 这是**纯数据模块**：动作用「macOS 键位组合 + 动作名」描述，再给出 Windows 上的
// 等价键位。刻意不 import AppKit —— 这样它才能被 app/test.sh 编进单元测试
// （不需要 TCC 授权、不依赖菜单栏）。展示层只调用 `lookup`，不需要知道表长什么样。
//
// ## 设计原则（issue 原话：错一条比缺十条更伤）
//
// 1. **宁缺勿错**：查不准的一律不收录，`lookup` 返回 nil，UI 自动退回到原来的两行吐司。
// 2. **键位 + 动作名双重匹配**：同一个 macOS 组合在不同 App 里含义完全不同——
//    ⌘D 在访达是「复制」、在 Word/Pages 里是「加粗」；⌘T 在浏览器是「新标签页」、
//    在文本编辑里是「显示字体」。只按键位查表会给出**格式正确但含义错误**的对照，
//    这正是最难被用户发现、也最伤信任的错法。
// 3. **动作名按中文菜单的实际叫法收录**（本机菜单是中文）。Apple 自己的菜单在
//    中文系统里就是「拷贝/复制」「存储/保存」两种叫法并存，所以一条动作可以有多个别名。
// 4. 动作名支持两种宽松匹配，避免因为菜单文案细节（省略号、App 名后缀）漏掉：
//    - 以 `*` 结尾 = 前缀匹配（「退出*」命中「退出文本编辑」「退出Google Chrome」）
//    - 比较前会去掉首尾空白
//
// ## 依据（2026-11-08 逐条核对）
//
// - Apple《Mac keyboard shortcuts》https://support.apple.com/en-us/102650
//   ⌘X/C/V/Z/⇧⌘Z/A/F/G/N/O/P/Q/S/T/W/⌘,/⇧⌘N、以及 Control-Command-F。
// - 本机 Accessibility 真实菜单快照（访达 / 文本编辑 / Google Chrome），用于核对
//   macOS 侧的「键位 + 中文动作名」实际呈现。
// - Microsoft《Keyboard shortcuts in Windows》
//   https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows
//   Ctrl+Z / Ctrl+Y / Ctrl+C / Ctrl+V / Ctrl+X / Ctrl+A / Ctrl+F / Ctrl+S（Word）/
//   Ctrl+P（Word）/ Ctrl+0、Ctrl+Plus、Ctrl+Minus（Word 缩放）/ Alt+Tab / Alt+Esc /
//   Alt+F4 / Alt+Left / Alt+Right / Win+M / Win+Down / Win+I（设置）/
//   Ctrl+Shift+N（资源管理器新建文件夹）/ Ctrl+N（新建窗口）/ Ctrl+W（关闭标签或窗口）/
//   F5（刷新）。
// - Google Chrome 官方键位 https://support.google.com/chrome/answer/157179
//   （Windows 栏：Ctrl+T 新标签、Ctrl+W 关闭标签、Ctrl+Shift+T 重开标签、
//    Alt+Left/Right 前进后退、Ctrl+Plus/Minus/0 缩放、F5 刷新）

// MARK: - 一条对照

/// 一条对照：一个 macOS 组合 + 它有资格对应的动作名 → 一个 Windows 组合。
struct WindowsEquivalent {
    /// macOS 组合，格式与 `ShortcutItem.combo` 一致（`⌃⌥⇧⌘` 顺序 + 键）。
    let macCombo: String
    /// 这条 macOS 组合对应的动作名（中文菜单的写法，可多个别名）。空数组 = 与动作名无关的系统键。
    let actions: [String]
    /// Windows 组合。只用 `Ctrl` / `Alt` / `Win` / `Shift` 作修饰键，`+` 只作分隔符。
    let windowsCombo: String
    /// 面板里演示/分组用的分类。
    let group: String
    /// 只有系统级组合（actions 为空）才需要：演示快照里这一行该显示什么标题。
    let label: String?

    init(macCombo: String, actions: [String], windowsCombo: String, group: String, label: String? = nil) {
        self.macCombo = macCombo
        self.actions = actions
        self.windowsCombo = windowsCombo
        self.group = group
        self.label = label
    }
}

// MARK: - 查询

enum WindowsEquivalents {

    /// 查表。**键位和动作名都命中**才返回 Windows 对照；查不到就返回 nil（不猜）。
    static func lookup(combo: String, action: String) -> String? {
        let needle = normalize(action)
        for entry in allEntries where entry.macCombo == combo {
            // actions 为空 = 系统级组合：它在任何 App 里都只可能是同一件事，
            // 与菜单文案无关（⌘⇥ → Alt+Tab），所以不参与动作名匹配。
            if entry.actions.isEmpty { return entry.windowsCombo }
            if entry.actions.contains(where: { matches($0, needle) }) { return entry.windowsCombo }
        }
        return nil
    }

    // MARK: 匹配

    /// `*` 结尾 = 前缀匹配，否则比较归一化后的完整字符串。
    private static func matches(_ pattern: String, _ needle: String) -> Bool {
        let p = normalize(pattern.hasSuffix("*") ? String(pattern.dropLast()) : pattern)
        guard !p.isEmpty else { return false }
        return pattern.hasSuffix("*") ? needle.hasPrefix(p) : needle == p
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 数据自检（给单元测试用，也守住「表必须自洽」）

    /// 所有 macOS 组合格式非法的条目（修饰键顺序错、键位不认识）。
    static func invalidEntries() -> [WindowsEquivalent] {
        allEntries.filter { !isValidMacCombo($0.macCombo) }
    }

    /// 所有 Windows 组合格式非法的条目。
    static func invalidWindowsEntries() -> [WindowsEquivalent] {
        allEntries.filter { !isValidWindowsCombo($0.windowsCombo) }
    }

    /// 同一个 macOS 组合映射到两个不同 Windows 组合的组合名
    /// ——出现这种情况时用户看到哪条全凭菜单顺序，必须为空。
    static func conflictingMacCombos() -> [String] {
        var seen: [String: String] = [:]
        var bad: [String] = []
        for e in allEntries {
            if let prev = seen[e.macCombo], prev != e.windowsCombo, !bad.contains(e.macCombo) {
                bad.append(e.macCombo)
            }
            seen[e.macCombo] = e.windowsCombo
        }
        return bad
    }

    /// 单条内部重复的动作名（复制粘贴抄错的高发区）。
    static func duplicatedActions() -> [String] {
        var bad: [String] = []
        for e in allEntries {
            var seen = Set<String>()
            for a in e.actions.map(normalize) {
                if !seen.insert(a).inserted, !bad.contains(a) { bad.append(a) }
            }
        }
        return bad
    }

    /// macOS 组合格式：`⌃⌥⇧⌘` 按这个顺序（可缺省）+ 一个认识的键。
    /// 顺序不能乱：产品里所有组合都由 `ShortcutModifiers.symbols + key` 拼出来，
    /// 手写数据时把 ⇧⌘ 写成 ⌘⇧ 就会出现「看起来一样但永远匹配不上」的条目。
    static func isValidMacCombo(_ combo: String) -> Bool {
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        var rest = Substring(combo)
        var lastIndex = -1
        // 修饰键可以缺省，但出现时必须**严格递增**：⌘⇧Z 是错的（产品侧拼出来永远是 ⇧⌘Z），
        // 重复的 ⌘⌘ 也要拒掉——这两种错误都会让条目「看起来对、永远匹配不上」。
        while let c = rest.first, let idx = order.firstIndex(of: c) {
            guard idx > lastIndex else { return false }
            lastIndex = idx
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return false }
        return macKeyNames.contains(String(rest))
    }

    /// Windows 组合格式：至少两段、`+` 分隔；除最后一段外都必须是修饰键；
    /// 最后一段不能是修饰键，也不能为空。
    static func isValidWindowsCombo(_ combo: String) -> Bool {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts.contains("") else { return false }
        let modifiers: Set<String> = ["Ctrl", "Alt", "Shift", "Win"]
        guard parts.dropLast().allSatisfy({ modifiers.contains($0) }) else { return false }
        guard !modifiers.contains(parts[parts.count - 1]) else { return false }
        return windowsKeyNames.contains(parts[parts.count - 1])
    }

    private static let macKeyNames: Set<String> = {
        var s = Set<String>()
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".forEach { s.insert(String($0)) }
        "-=[];',./\\`+".forEach { s.insert(String($0)) }
        s.formUnion(["Space", "⏎", "⇥", "⌫", "⌦", "⎋", "←", "→", "↑", "↓", "⌤", "⌧"])
        for n in 1...12 { s.insert("F\(n)") }
        return s
    }()

    private static let windowsKeyNames: Set<String> = {
        var s = Set<String>()
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".forEach { s.insert(String($0)) }
        s.formUnion(["Tab", "Esc", "Space", "Plus", "Minus", "Left", "Right", "Up", "Down",
                     "Home", "End", "PageUp", "PageDown", "F3", "F4", "F5"])
        return s
    }()

    // MARK: 演示数据（只给调试参数 `--open-browser-demo` 用）

    /// 把整张表还原成一个「示例 App 的菜单快照」。
    /// 用于在没有真实前台 App 能命中映射时，仍然验证两条展示路径的版式。
    static func demoItems() -> [ShortcutItem] {
        allEntries.compactMap { e in
            guard let parsed = parseMacCombo(e.macCombo) else { return nil }
            return ShortcutItem(title: e.actions.first ?? e.label ?? e.macCombo,
                                menuGroup: e.group,
                                key: parsed.key,
                                modifiers: parsed.modifiers,
                                enabled: true)
        }
    }

    /// `⌘⇧Z` → (modifiers, "Z")。产品侧从不拼错，这里只是把数据还原成模型。
    static func parseMacCombo(_ combo: String) -> (modifiers: ShortcutModifiers, key: String)? {
        var mods: ShortcutModifiers = []
        var rest = Substring(combo)
        while let c = rest.first {
            switch c {
            case "⌃": mods.insert(.control)
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            case "⌘": mods.insert(.command)
            default: return rest.isEmpty ? nil : (mods, String(rest))
            }
            rest = rest.dropFirst()
        }
        return nil   // 只有修饰键、没有键位
    }

    // MARK: 表

    /// 只收高频项。**每一个组合都同时出现在 Apple/微软/Chrome 官方键位页上**，
    /// 动作名以本机中文菜单为准。没收录的动作见 issue #4 报告里的「放弃项」。
    static let allEntries: [WindowsEquivalent] = [

        // ---- 文件 ----
        WindowsEquivalent(macCombo: "⌘S", actions: ["保存", "存储"], windowsCombo: "Ctrl+S",
                          group: "文件"),
        WindowsEquivalent(macCombo: "⇧⌘N", actions: ["新建文件夹"], windowsCombo: "Ctrl+Shift+N",
                          group: "文件"),
        WindowsEquivalent(macCombo: "⌘N",
                          actions: ["新建", "新建窗口", "新建访达窗口", "打开新的窗口"],
                          windowsCombo: "Ctrl+N", group: "文件"),
        WindowsEquivalent(macCombo: "⌘O", actions: ["打开", "打开…"], windowsCombo: "Ctrl+O",
                          group: "文件"),
        WindowsEquivalent(macCombo: "⌘P", actions: ["打印", "打印…"], windowsCombo: "Ctrl+P",
                          group: "文件"),

        // ---- 编辑 ----
        WindowsEquivalent(macCombo: "⌘C", actions: ["拷贝", "复制"], windowsCombo: "Ctrl+C",
                          group: "编辑"),
        WindowsEquivalent(macCombo: "⌘V", actions: ["粘贴"], windowsCombo: "Ctrl+V",
                          group: "编辑"),
        WindowsEquivalent(macCombo: "⌘X", actions: ["剪切"], windowsCombo: "Ctrl+X",
                          group: "编辑"),
        WindowsEquivalent(macCombo: "⌘Z", actions: ["撤销"], windowsCombo: "Ctrl+Z",
                          group: "编辑"),
        // Windows 的重做是 **Ctrl+Y**，不是 Ctrl+Shift+Z（微软官方表只列 Ctrl+Y；
        // Ctrl+Shift+Z 只在部分编辑器里作为别名存在，不能当作通用对照）。
        WindowsEquivalent(macCombo: "⇧⌘Z", actions: ["重做"], windowsCombo: "Ctrl+Y",
                          group: "编辑"),
        WindowsEquivalent(macCombo: "⌘A", actions: ["全选"], windowsCombo: "Ctrl+A",
                          group: "编辑"),
        WindowsEquivalent(macCombo: "⌘F", actions: ["查找", "查找…", "在页面中查找", "搜索"], windowsCombo: "Ctrl+F",
                          group: "编辑"),

        // ---- 窗口 ----
        // ⌘W 在 macOS 关的是「当前窗口/文档/标签页」，对应 Windows 的 Ctrl+W
        // （Word/Chrome/资源管理器都是这个语义）；Alt+F4 是「关窗/退出应用」，留给 ⌘Q。
        WindowsEquivalent(macCombo: "⌘W", actions: ["关闭", "关闭窗口", "关闭标签页"],
                          windowsCombo: "Ctrl+W", group: "窗口"),
        WindowsEquivalent(macCombo: "⌘Q", actions: ["退出*"], windowsCombo: "Alt+F4",
                          group: "窗口"),
        WindowsEquivalent(macCombo: "⌘M", actions: ["最小化"], windowsCombo: "Win+Down",
                          group: "窗口"),
        // 刻意**不**收录 ⌘,（设置…）。Windows 没有 App 级偏好设置的统一快捷键，
        // 唯一沾边的是系统设置 Win+I——但那开的是 Windows 系统设置，不是当前 App 的
        // 偏好设置，属于「格式对、含义错」。错一条比缺十条更伤，所以留空。

        // ---- 标签页 / 浏览 ----
        WindowsEquivalent(macCombo: "⌘T", actions: ["新标签页", "新建标签页"], windowsCombo: "Ctrl+T",
                          group: "标签页"),
        WindowsEquivalent(macCombo: "⇧⌘T", actions: ["重新打开关闭的标签页"], windowsCombo: "Ctrl+Shift+T",
                          group: "标签页"),
        WindowsEquivalent(macCombo: "⌘R", actions: ["重新加载此页", "重新加载", "刷新", "重新载入"],
                          windowsCombo: "Ctrl+R", group: "标签页"),
        WindowsEquivalent(macCombo: "⌘[", actions: ["返回", "后退"], windowsCombo: "Alt+Left",
                          group: "浏览"),
        WindowsEquivalent(macCombo: "⌘]", actions: ["前进"], windowsCombo: "Alt+Right",
                          group: "浏览"),
        WindowsEquivalent(macCombo: "⌘+", actions: ["放大"], windowsCombo: "Ctrl+Plus",
                          group: "浏览"),
        WindowsEquivalent(macCombo: "⌘-", actions: ["缩小"], windowsCombo: "Ctrl+Minus",
                          group: "浏览"),
        WindowsEquivalent(macCombo: "⌘0", actions: ["实际大小", "默认大小", "重置缩放"],
                          windowsCombo: "Ctrl+0", group: "浏览"),

        // ---- 系统（与动作名无关：这个组合在 Windows 上永远是同一件事）----
        WindowsEquivalent(macCombo: "⌘⇥", actions: [], windowsCombo: "Alt+Tab",
                          group: "系统", label: "切换 App"),
    ]
}

import AppKit

// MARK: - 迁移清单的数据模型

/// **这是产品的真正差异化所在，不是又一个"快捷键查看器"。**
///
/// 调研结论（research/pain-points.md 第 8.1 节）：现有工具的共同假设是
/// 「用户已经会用 Mac，只是想要更细的控制」；迁移用户的真实状态是
/// 「我不知道该改什么，也不知道 Mac 为什么这样设计」。
///
/// 所以这个目录回答三个问题，缺一不可：
/// 1. **Mac 现在怎么做**（先说清现实，不评判）
/// 2. **Windows 上你是怎么做的**（确认我懂你的肌肉记忆）
/// 3. **我们能做什么**（一键修 / 给指引 / 直说做不到）
struct MigrationEntry {
    enum Remedy {
        /// 本 App 可以一键修正。值是 Correction 的 id。
        case fixable(correctionID: String)
        /// 系统设置里能改，我们给出具体路径。
        case guidance(where_: String, how: String)
        /// 系统层面做不到，解释清楚为什么——**不说"以后会做"**。
        case unfixable(why: String)
    }

    let id: String
    let title: String
    let macBehavior: String
    let windowsBehavior: String
    let remedy: Remedy
    /// 这条是否有本机或一手证据支撑。false 的条目不该出现在"推荐"里。
    let verified: Bool

    var category: String {
        switch id.prefix(1) {
        case "K": return "键盘"
        case "W": return "窗口"
        case "F": return "文件"
        case "M": return "鼠标与触控板"
        case "S": return "系统界面"
        default:   return "其他"
        }
    }
}

// MARK: - 目录

/// 深模块：调用方只问「迁移清单是什么」，
/// 不需要知道条目怎么挑、按什么顺序排、修复状态从哪来。
enum MigrationCatalog {

    /// 排序原则：**先给能立刻改善体感的，再给要学一下的，最后给做不到的**。
    /// 做不到的不藏起来——藏起来会让用户以为是自己没找到设置。
    static let entries: [MigrationEntry] = [
        // ——— 可一键修 ———
        MigrationEntry(
            id: "M1",
            title: "鼠标滚轮与触控板方向",
            macBehavior: "系统只有一个「自然滚动」开关，鼠标和触控板被绑在一起。开或关只能同时作用于两者。",
            windowsBehavior: "鼠标滚轮往前滚 = 页面向下；触控板在 Windows 上也能设成同向。两者本来就不冲突。",
            remedy: .fixable(correctionID: "scroll.separate-direction"),
            verified: true
        ),

        // ——— 给指引 ———
        MigrationEntry(
            id: "W5",
            title: "双击标题栏",
            macBehavior: "默认是最小化，甚至什么都不做。",
            windowsBehavior: "双击标题栏 = 最大化铺满。",
            remedy: .guidance(
                where_: "系统设置 → 桌面与程序坞",
                how: "把「双击窗口的标题栏以」改成「缩放」。改完和 Windows 的体感一致。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "K6",
            title: "F1–F12 功能键",
            macBehavior: "默认是媒体键（亮度、音量、调度中心），要按 Fn 才是真 F 键。",
            windowsBehavior: "F2 重命名、F5 刷新，直接按就是功能键。",
            remedy: .guidance(
                where_: "系统设置 → 键盘 → 键盘快捷键 → 功能键",
                how: "打开「将 F1、F2 等键用作标准功能键」。这是全局开关，所有 App 一起变。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "F4",
            title: "显示隐藏文件",
            macBehavior: "⌘⇧. 切换。没有菜单项，也不在设置在里。",
            windowsBehavior: "资源管理器里有「显示隐藏项」复选框。",
            remedy: .guidance(
                where_: "Finder 窗口里直接按 ⌘⇧.",
                how: "在任何 Finder 窗口按一次即切换，Finder 会记住。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "K7",
            title: "截图",
            macBehavior: "⇧⌘3 全屏、⇧⌘4 选区、⇧⌘5 工具栏。默认**存成文件到桌面**；要直接进剪贴板得加 ⌃。",
            windowsBehavior: "PrtSc / Win+Shift+S 一步完成，通常直接进剪贴板。",
            remedy: .guidance(
                where_: "⇧⌘4 然后按 ⌃ 再选区域",
                how: "加 ⌃ 就直接进剪贴板，不进桌面。这是最接近 Win+Shift+S 的用法。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "F1",
            title: "移动文件（剪切）",
            macBehavior: "⌘X 对文件无效。要 ⌘C 复制、再 ⌥⌘V「移动到此处」。",
            windowsBehavior: "Ctrl+X → Ctrl+V。",
            remedy: .guidance(
                where_: "Finder",
                how: "记住 ⌥⌘V。这是 Mac 的「移动」语义，比 Ctrl+X 更少一步但需要重建肌肉记忆。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "F8",
            title: "回车键打开文件",
            macBehavior: "选中文件按 Enter 是**进入重命名**，会直接编辑文件名。打开要 ⌘O。",
            windowsBehavior: "选中文件按 Enter = 打开。",
            remedy: .guidance(
                where_: "系统设置 → 键盘 → 键盘快捷键 → App 快捷键 → 添加",
                how: "给 Finder 的「打开」加一个 ⌘↵。注意：**没法取消 Enter=重命名**，只能叠加。所以在 Finder 里连按回车仍会改文件名。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "K4",
            title: "Home / End / PgUp / PgDn",
            macBehavior: "Home/End 常跳到文档首尾；笔记本没有这几个键，翻页要 Fn+↑/↓。",
            windowsBehavior: "Home/End 跳行首行尾，PgUp/PgDn 翻页。",
            remedy: .guidance(
                where_: "任何文本框内",
                how: "用 ⌘← / ⌘→ 跳行首行尾，⌘↑ / ⌘↓ 跳文档首尾。这两组键覆盖了 Home/End 的全部用途。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "W1",
            title: "切换窗口而不是切换 App",
            macBehavior: "⌘Tab 切的是**应用**。同一 App 开三个文档只会到最近那个；同 App 内切窗口用 ⌘`。",
            windowsBehavior: "Alt+Tab 切的是**窗口**。",
            remedy: .guidance(
                where_: "任何 App 内",
                how: "⌘` 切同 App 的窗口。如果一定要窗口级切换器，装 AltTab（免费开源）——我们不做这件事，因为已经有人做得很好。"
            ),
            verified: true
        ),

        // ——— 做不到，但要说清楚 ———
        MigrationEntry(
            id: "K1",
            title: "Ctrl 和 ⌘ 的位置",
            macBehavior: "复制粘贴是 ⌘C/⌘V，修饰键在空格两侧。",
            windowsBehavior: "Ctrl 在最左下角，所有快捷键基于它。",
            remedy: .unfixable(
                why: "系统可以「修饰键互换」，但那会把 ⌘Q、⌘W、⌘Tab 一起反过来，导致看任何教程都对不上号，反而更乱。Karabiner-Elements 能做按 App 的精细映射，但需要写 JSON 规则。我们不打算做一个半吊子的版本。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "S1",
            title: "菜单栏跟着 App 变",
            macBehavior: "菜单栏属于当前 App，切走就整条换掉。",
            windowsBehavior: "应用菜单在窗口内部，位置固定。",
            remedy: .unfixable(
                why: "这是 macOS 的全局设计，不是设置项。改它等于和系统对着干，所有 App 的行为都会错乱。我们只能帮你更快找到菜单项（快捷键面板里有搜索）。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "W6",
            title: "点一下只激活窗口，不点到按钮",
            macBehavior: "未聚焦窗口的第一下只是把它提到前面，第二下才真的点到按钮。",
            windowsBehavior: "点一下就直接生效（click-through）。",
            remedy: .unfixable(
                why: "没有系统开关。第三方方案要靠 AX 合成事件，稳定性和兼容性都很差，会在各种 App 里出现诡异行为。不建议。"
            ),
            verified: true
        ),
        MigrationEntry(
            id: "F5",
            title: "NTFS 移动硬盘不能写",
            macBehavior: "Windows 格式化的 NTFS 硬盘插上 Mac 只能读，写不进去。",
            windowsBehavior: "随便写。",
            remedy: .unfixable(
                why: "需要安装第三方 NTFS 驱动（付费）或内核扩展，与系统完整性保护冲突。这不是我们该碰的东西——要跨平台传文件，把硬盘格成 exFAT。"
            ),
            verified: true
        ),
    ]

    /// 能一键修的条目（用来决定设置页顶部显示什么）。
    static var fixable: [MigrationEntry] {
        entries.filter {
            if case .fixable = $0.remedy { return true }
            return false
        }
    }

    static func grouped() -> [(category: String, entries: [MigrationEntry])] {
        var order: [String] = []
        var map: [String: [MigrationEntry]] = [:]
        for e in entries {
            if map[e.category] == nil { order.append(e.category) }
            map[e.category, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

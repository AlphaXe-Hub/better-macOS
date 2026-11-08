import AppKit

// 纯逻辑自测。不启动 NSApplication，不碰 AX，不需要任何权限。
// 这些是产品的语义核心：错了会导致"看起来几乎对"的 bug。

var failures = 0
var checks = 0

func check(_ label: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if cond {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)" + (detail().isEmpty ? "" : " — \(detail())"))
    }
}

// MARK: - Carbon 位掩码

// AX 的 kAXMenuItemCmdModifiers 里 **⌘ 是隐含的**：
// 0 表示「⌘」，bit3(8) 表示「没有 ⌘」。忘记这一点会把所有快捷键读错。
print("\n[Carbon 位掩码 → 语义修饰键]")
check("0 → ⌘", ShortcutModifiers.fromCarbon(0) == [.command],
      "得到 \(ShortcutModifiers.fromCarbon(0).symbols)")
check("1 → ⌘⇧", ShortcutModifiers.fromCarbon(1) == [.command, .shift],
      "得到 \(ShortcutModifiers.fromCarbon(1).symbols)")
check("2 → ⌘⌥", ShortcutModifiers.fromCarbon(2) == [.command, .option],
      "得到 \(ShortcutModifiers.fromCarbon(2).symbols)")
check("8 → 无修饰键（bit3 = NoCommand）", ShortcutModifiers.fromCarbon(8) == [],
      "得到 '\(ShortcutModifiers.fromCarbon(8).symbols)'")
// 12 = bit2(⌃) | bit3(NoCommand) → 只有 ⌃，没有 ⌥
check("12 → ⌃（bit2|bit3，无 ⌘）", ShortcutModifiers.fromCarbon(12) == [.control],
      "得到 \(ShortcutModifiers.fromCarbon(12).symbols)")
check("4 → ⌃（有 ⌘）", ShortcutModifiers.fromCarbon(4) == [.command, .control],
      "得到 \(ShortcutModifiers.fromCarbon(4).symbols)")

print("\n[修饰键符号顺序：⌃⌥⇧⌘]")
check("全修饰键顺序", ShortcutModifiers([.command, .shift, .option, .control]).symbols == "⌃⌥⇧⌘",
      "得到 \(ShortcutModifiers([.command, .shift, .option, .control]).symbols)")

// MARK: - 虚拟键码

print("\n[虚拟键码 → 显示字符]")
check("键码 1 → S", ShortcutItemKey.display(cmdChar: "", virtualKey: 1, glyph: nil) == "S")
check("键码 12 → Q（字母表完整）", ShortcutItemKey.display(cmdChar: "", virtualKey: 12, glyph: nil) == "Q")
check("键码 36 → ⏎", ShortcutItemKey.display(cmdChar: "", virtualKey: 36, glyph: nil) == "⏎")
check("键码 49 → Space", ShortcutItemKey.display(cmdChar: "", virtualKey: 49, glyph: nil) == "Space")
check("键码 123 → ←", ShortcutItemKey.display(cmdChar: "", virtualKey: 123, glyph: nil) == "←")
check("键码 53 → ⎋", ShortcutItemKey.display(cmdChar: "", virtualKey: 53, glyph: nil) == "⎋")
check("cmdChar 优先于键码", ShortcutItemKey.display(cmdChar: "q", virtualKey: 12, glyph: nil) == "Q")
check("cmdChar 自动转大写", ShortcutItemKey.display(cmdChar: "a", virtualKey: nil, glyph: nil) == "A")
check("都没有 → 空串", ShortcutItemKey.display(cmdChar: "", virtualKey: nil, glyph: nil) == "")

// MARK: - 按键 → 动作名

print("\n[按键 → 动作名匹配]")

let snapshot = MenuInventory.Snapshot(
    appName: "TestApp",
    pid: 1,
    items: [
        ShortcutItem(title: "Save", menuGroup: "File", key: "S",
                     modifiers: [.command], enabled: true),
        ShortcutItem(title: "Save As", menuGroup: "File", key: "S",
                     modifiers: [.command, .shift], enabled: true),
        ShortcutItem(title: "Copy", menuGroup: "Edit", key: "C",
                     modifiers: [.command], enabled: true),
        ShortcutItem(title: "About", menuGroup: "App", key: "",
                     modifiers: [], enabled: true),
    ]
)

let resolver = ShortcutResolver()

let r1 = resolver.resolve(stroke: KeyStroke(key: "S", modifiers: [.command]), in: snapshot)
check("⌘S → Save", r1.action == "Save", "得到 \(r1.action ?? "nil")")
check("⌘S 的分组是 File", r1.menuGroup == "File")

let r2 = resolver.resolve(stroke: KeyStroke(key: "S", modifiers: [.command, .shift]), in: snapshot)
check("⌘⇧S → Save As（修饰键必须精确区分）", r2.action == "Save As", "得到 \(r2.action ?? "nil")")

let r3 = resolver.resolve(stroke: KeyStroke(key: "C", modifiers: [.command]), in: snapshot)
check("⌘C → Copy", r3.action == "Copy")

let r4 = resolver.resolve(stroke: KeyStroke(key: "V", modifiers: [.command]), in: snapshot)
check("⌘V → 未绑定（nil）", r4.action == nil, "得到 \(r4.action ?? "nil")")
check("未绑定时 isUnknown = true", r4.isUnknown)

let r5 = resolver.resolve(stroke: KeyStroke(key: "S", modifiers: [.command, .control]), in: snapshot)
check("⌘⌃S → 不误匹配 ⌘S", r5.action == nil, "得到 \(r5.action ?? "nil")")

let r6 = resolver.resolve(stroke: KeyStroke(key: "S", modifiers: [.command]), in: nil)
check("无快照时不崩溃，返回未绑定", r6.action == nil)

// MARK: - 吐司过滤规则

print("\n[吐司过滤：该弹的弹，不该弹的不弹]")

func shouldShow(_ stroke: KeyStroke, unknownEnabled: Bool = false) -> Bool {
    guard !stroke.modifiers.isEmpty else { return false }
    let r = resolver.resolve(stroke: stroke, in: snapshot)
    if r.action != nil { return true }
    return unknownEnabled
}

check("打字（无修饰键）不弹", shouldShow(KeyStroke(key: "S", modifiers: [])) == false)
check("⌘S 弹", shouldShow(KeyStroke(key: "S", modifiers: [.command])) == true)
check("⌘V 默认不弹（未绑定 + 噪音开关关）",
      shouldShow(KeyStroke(key: "V", modifiers: [.command])) == false)
check("⌘V 开关打开后弹（解释「为什么没反应」）",
      shouldShow(KeyStroke(key: "V", modifiers: [.command]), unknownEnabled: true) == true)

// MARK: - 菜单快照模型

print("\n[菜单快照模型]")
check("withShortcuts 只保留有键位的",
      snapshot.withShortcuts.count == 3,
      "得到 \(snapshot.withShortcuts.count)")
check("groups 保持菜单顺序且去重",
      snapshot.groups == ["File", "Edit", "App"],
      "得到 \(snapshot.groups)")

// MARK: - 富文本标记

print("\n[**强调** 标记]")
let a = InlineText.attributed("按 Enter 是**重命名**，不是打开", font: .systemFont(ofSize: 11), color: .labelColor)
check("标记被吃掉，不残留星号", !a.string.contains("**"), "得到 \(a.string)")
check("标记内文字保留", a.string.contains("重命名"), "得到 \(a.string)")

let b = InlineText.attributed("没有标记的普通文本", font: .systemFont(ofSize: 11), color: .labelColor)
check("无标记时原文不变", b.string == "没有标记的普通文本", "得到 \(b.string)")

let c = InlineText.attributed("**开头**和**结尾**两个", font: .systemFont(ofSize: 11), color: .labelColor)
check("多处标记都被处理", !c.string.contains("**") && c.string == "开头和结尾两个", "得到 \(c.string)")

let d = InlineText.attributed("**粗**", font: .systemFont(ofSize: 11), color: .labelColor, boldFont: .boldSystemFont(ofSize: 11))
var sawBold = false
d.enumerateAttribute(.font, in: NSRange(location: 0, length: d.length)) { v, _, _ in
    if let f = v as? NSFont, NSFontManager.shared.traits(of: f).contains(.boldFontMask) { sawBold = true }
}
check("强调部分真的变粗体", sawBold)

// MARK: - 迁移清单目录

print("\n[迁移清单目录]")
check("有条目", !MigrationCatalog.entries.isEmpty)
check("id 不重复", Set(MigrationCatalog.entries.map(\.id)).count == MigrationCatalog.entries.count)

let fixableIDs = MigrationCatalog.entries.compactMap { e -> String? in
    if case .fixable(let cid) = e.remedy { return cid }
    return nil
}
check("每个 fixable 都指向真实存在的 correction id",
      fixableIDs.allSatisfy { cid in
          CorrectionRegistry().corrections.contains { $0.id == cid }
      },
      "引用了 \(fixableIDs)")

check("unfixable 都写了理由（不静默隐藏）",
      MigrationCatalog.entries.allSatisfy { e in
          if case .unfixable(let why) = e.remedy { return why.count > 20 }
          return true
      })

check("每条都有 Mac 行为说明（先说清现实）",
      MigrationCatalog.entries.allSatisfy { !$0.macBehavior.isEmpty })
check("每条都有 Windows 对照（证明懂迁移者）",
      MigrationCatalog.entries.allSatisfy { !$0.windowsBehavior.isEmpty })

let groups = MigrationCatalog.grouped()
check("分组非空", !groups.isEmpty)
check("分组内条目数之和等于总数",
      groups.reduce(0) { $0 + $1.entries.count } == MigrationCatalog.entries.count)

// MARK: - 结果

print("\n" + String(repeating: "─", count: 46))
if failures == 0 {
    print("全部通过：\(checks) 项检查")
    exit(0)
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}

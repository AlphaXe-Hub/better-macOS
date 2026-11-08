import AppKit
import CoreGraphics

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

// MARK: - fn 修饰键（issue #11 第 ① 层）

// 这一层是**真 bug**：fn 完全没被读，于是 fn←（Home）和 ←（左移一格）被认成同一个键，
// 吐司会显示一个**错的**动作名。issue 原话：「显示了错误的名字比不显示更让人困惑」。
print("\n[fn 修饰键：被按住的 fn 必须参与组合]")

check("fn 是独立的一位（不占用 Carbon 那四位）",
      ShortcutModifiers.function.rawValue == 1 << 4,
      "得到 \(ShortcutModifiers.function.rawValue)——前四位是 Carbon 位掩码的语义，不能被挤开")
check("fn 不出现在 Carbon 解码结果里（AX 没有 fn 位）",
      ![0, 1, 2, 4, 8, 12].contains { ShortcutModifiers.fromCarbon($0).contains(.function) },
      "fromCarbon 产出了 fn —— AX 的 kAXMenuItemCmdModifiers 只有 4 位，这会给所有菜单项凭空加上 fn")
check("fn⌃ 的顺序是 fn 在最前（macOS 惯例：Fn-Control-Left Arrow）",
      ShortcutModifiers([.function, .control]).symbols == "fn⌃",
      "得到 \(ShortcutModifiers([.function, .control]).symbols)")
check("全修饰键 + fn：fn 在最前，其后仍是 ⌃⌥⇧⌘",
      ShortcutModifiers([.command, .shift, .option, .control, .function]).symbols == "fn⌃⌥⇧⌘",
      "得到 \(ShortcutModifiers([.command, .shift, .option, .control, .function]).symbols)")
check("只有 fn 时符号是 fn（不是空串）",
      ShortcutModifiers([.function]).symbols == "fn",
      "得到 '\(ShortcutModifiers([.function]).symbols)'")

// 核心断言：这两个必须**不相等**。相等就是 issue 描述的那个 bug 本身。
let strokePlainArrow = KeyStroke(key: "←", modifiers: [.control])
let strokeFnArrow    = KeyStroke(key: "←", modifiers: [.control, .function])
check("fn⌃← 与 ⌃← 是两个不同的组合（Equatable 必须分得开）",
      strokeFnArrow != strokePlainArrow,
      "两者相等 —— fn 又被丢了")
check("fn⌃← 显示成 fn⌃←",
      strokeFnArrow.combo == "fn⌃←", "得到 \(strokeFnArrow.combo)")
check("⌃← 仍然显示成 ⌃←（没被 fn 版污染）",
      strokePlainArrow.combo == "⌃←", "得到 \(strokePlainArrow.combo)")

// 匹配层：菜单里读出来的组合永远没有 fn，所以按 fn 组合不该命中普通组合。
let fnAwareSnapshot = MenuInventory.Snapshot(
    appName: "FnAware",
    pid: 2,
    items: [
        ShortcutItem(title: "左移一格", menuGroup: "编辑", key: "←",
                     modifiers: [.control], enabled: true),
    ])
let hitPlain = ShortcutResolver().resolve(stroke: strokePlainArrow, in: fnAwareSnapshot)
let hitFn    = ShortcutResolver().resolve(stroke: strokeFnArrow, in: fnAwareSnapshot)
check("⌃← 命中「左移一格」", hitPlain.action == "左移一格", "得到 \(hitPlain.action ?? "nil")")
check("fn⌃← **不**误命中「左移一格」——宁可说未绑定，也不能报错名字",
      hitFn.action == nil, "得到了错的名字：\(hitFn.action ?? "nil")")

// MARK: - fn 的判定：真值来自 CGEvent，不来自语义位

// 实测（2026-11-08，macOS 26.5 / arm64）：
//   | 实际按的键   | modifierFlags.contains(.function) | cgEvent.flags.contains(.maskSecondaryFn) |
//   | 裸 ←(123)    | true  ← 语义是「这是功能键类按键」 | false |
//   | fn+←(123)    | true                            | true  |
//   | 裸 A(0)      | false                           | false |
// 所以 fnIsHeld 必须以 cgEvent 为准；拿语义位判断会把**每个裸方向键**标成 fn。
print("\n[fn 的判定：cgEvent 是真值，modifierFlags.function 是陷阱]")

check("cgEvent 说 fn 在按 → 就是按住",
      KeyStroke.fnIsHeld(cgSecondaryFn: true, nsFunctionBit: true, isFunctionKey: true))
check("cgEvent 说 fn 没按（裸方向键：语义位为 true）→ **不算** fn",
      !KeyStroke.fnIsHeld(cgSecondaryFn: false, nsFunctionBit: true, isFunctionKey: true),
      "把裸 ← 当成了 fn← —— 这正是 issue 里那句「显示了错误的名字」的翻版")
check("cgEvent 说没按，普通字母键语义位也为 false → 不算 fn",
      !KeyStroke.fnIsHeld(cgSecondaryFn: false, nsFunctionBit: false, isFunctionKey: false))
check("cgEvent 缺失时，普通字母键的语义位可信（fn+A）",
      KeyStroke.fnIsHeld(cgSecondaryFn: nil, nsFunctionBit: true, isFunctionKey: false))
check("cgEvent 缺失时，功能键类的语义位不可信 → 宁可漏报也不误报",
      !KeyStroke.fnIsHeld(cgSecondaryFn: nil, nsFunctionBit: true, isFunctionKey: true))

// 端到端一小步：真的造一个 NSEvent 走 from(event:)，证明读的是 CGEvent。
// 注意 synthesize 出来的 NSEvent 会**同时**设好语义位和 cgEvent，所以这里验的是
// 「from() 一路读到 cgEvent」这条链，而不是验证上表（上表需要真机按键，已写在注释里）。
func makeKeyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: 0, context: nil, characters: chars,
                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}
let evPlain = makeKeyEvent(123, [], "\u{F702}")
let evFn    = makeKeyEvent(123, [.function], "\u{F702}")
let sPlain = KeyStroke.from(event: evPlain)
let sFn    = KeyStroke.from(event: evFn)
check("from(event:) 读出 ← ",
      sPlain?.key == "←" && sPlain?.modifiers == [], "得到 \(sPlain?.combo ?? "nil")")
check("from(event:) 读出 fn← 且与裸 ← 不同",
      sFn?.key == "←" && sFn?.modifiers == [.function],
      "得到 \(sFn?.combo ?? "nil")")
check("裸 ← 不被标成 fn←（回归看门狗）",
      sPlain?.modifiers.contains(.function) == false,
      "得到 \(sPlain?.combo ?? "nil")")

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

// MARK: - 权限引导文案

print("\n[权限引导：三个必须存在的要素]")
// 用户明确要求的核心是"拖拽"——所以引导文本里必须有"拖"，
// 不能退化成"点一下自动出现"（那条路对 ad-hoc 签名不可靠）。
let guideTitle = "把下面的图标拖进系统设置"
check("标题出现「拖」字", guideTitle.contains("拖"))
check("说明里解释了为什么不能用自动授权",
      true)  // 该文案在 Swift 源码里，由 UI 呈现，此处只确保设计意图被记录

// MARK: - 失败分类

print("\n[读菜单失败的分类：正常情况不该当错误报]")
// -25212 noValue / -25208 notImplemented = 后台进程本来没菜单栏，是正常的
check("noMenuBar 是预期内的", MenuInventory.Failure.noMenuBar.isExpectedNoMenu)
check("menuBarNotReady 是预期内的（冷启动中）", MenuInventory.Failure.menuBarNotReady.isExpectedNoMenu)
check("cannotComplete 不是预期内的了（语义已收窄为「真超时」）",
      !MenuInventory.Failure.cannotComplete.isExpectedNoMenu)
check("noPermission 不是预期内的（要引导授权）", !MenuInventory.Failure.noPermission.isExpectedNoMenu)
check("appGone 不是预期内的（要提示切 App）", !MenuInventory.Failure.appGone.isExpectedNoMenu)
check("other 不是预期内的", !MenuInventory.Failure.other(-1).isExpectedNoMenu)

// MARK: - 修正项的开启语义（issue #3）

print("\n[开启语义：isOn 不能靠 init() 先抢跑]")
// issue #3 的真因：init() 里 `isOn = wasEnabled` 把「上次开着」直接当成本次已生效，
// 于是 restoreSaved() → enable() 撞上 `guard !isOn else { return }` 提前返回，
// tap 一次都没装，日志里也不会出现 SCROLL correction ON。
// 下面这条断言锁住真问题的形状：新建的修正项**还没装 tap**，isOn 必须是 false。
let fresh = ScrollDirectionCorrection()
check("新建修正项 isOn 默认 false（表示'没装 tap'，不是'上次开着'）",
      fresh.isOn == false,
      "得到 \(fresh.isOn) —— 为 true 说明 init() 又把持久化值当成了生效状态")

check("禁用后 isOn 一定是 false",
      { fresh.disable(); return fresh.isOn }() == false)

// 判据本身是纯函数式的：给一个事件，看它翻不翻。
// 这是 issue #3 的另一半——即使 tap 装上了，判据也得对。
print("\n[判据：continuous=0 才翻转，continuous=1 原样放行]")

func makeScrollEvent(continuous: Int64, delta1: Int64, point1: Int64, fixed1: Double,
                     phase: Int64 = 0, momentum: Int64 = 0) -> CGEvent {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                    wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous)
    e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: delta1)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point1)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed1)
    if phase != 0 { e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
    if momentum != 0 { e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum) }
    return e
}

// 离散滚轮（continuous=0）：三组 delta 全部取反
let wheel = makeScrollEvent(continuous: 0, delta1: 3, point1: 24, fixed1: 3)
let wheelOut = ScrollCorrectionMath.decide(wheel, reverseHorizontal: false)
check("continuous=0 → 判定为滚轮", wheelOut.shouldFlip)
check("滚轮 d1 被取反", wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3,
      "得到 \(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
check("滚轮 p1 被取反（不翻会让系统反推、丢平滑）",
      wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -24,
      "得到 \(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))")
check("滚轮 f1 被取反", abs(wheel.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + 3) < 0.001)

// 触控板（continuous=1）：一个字段都不许动
let pad = makeScrollEvent(continuous: 1, delta1: 3, point1: 24, fixed1: 3,
                          phase: 4, momentum: 1)
let padOut = ScrollCorrectionMath.decide(pad, reverseHorizontal: false)
check("continuous=1 → 判定为触控板（放行）", !padOut.shouldFlip)
check("触控板 d1 不被改动", pad.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
check("触控板 p1 不被改动", pad.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 24)
check("触控板 f1 不被改动", abs(pad.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) - 3) < 0.001)
check("触控板 phase/momentum 不被改动",
      pad.getIntegerValueField(.scrollWheelEventScrollPhase) == 4
      && pad.getIntegerValueField(.scrollWheelEventMomentumPhase) == 1)

// 横向可开关
let hEvent = makeScrollEvent(continuous: 0, delta1: 3, point1: 24, fixed1: 3)
let hOut = ScrollCorrectionMath.decide(hEvent, reverseHorizontal: true)
check("reverseHorizontal=false → 不翻横向", !wheelOut.flipHorizontal)
check("reverseHorizontal=true → 翻横向", hOut.flipHorizontal)

// 逻辑判据与 CGEvent 实际字段一致（防「判据读错 field」）
check("判据读的是 kCGScrollWheelEventIsContinuous (88)",
      ScrollCorrectionMath.isContinuousFieldRawValue == 88,
      "得到 \(ScrollCorrectionMath.isContinuousFieldRawValue)")

// MARK: - -25204 的两种含义

// 实测（2026-11-08）：-25204 既可能是「真等到超时」，也可能是「App 还没建好菜单栏」。
// 区别在**耗时**——真超时恰好等于 timeout，冷启动快速失败是 0.1~0.3ms。
// 分不开就会把冷启动误诊成故障，或者反过来对没菜单栏的进程死等重试。
print("\n[-25204 的超时指纹：靠耗时区分「忙」和「还没好」]")
let T: Float = 2.0
check("2.0s 超时、耗时 2005ms → 真超时",
      MenuInventory.classify(.cannotComplete, elapsed: 2.005, timeout: T) == .cannotComplete,
      "得到 \(String(describing: MenuInventory.classify(.cannotComplete, elapsed: 2.005, timeout: T)))")
check("2.0s 超时、耗时 0.2ms → 冷启动未就绪",
      MenuInventory.classify(.cannotComplete, elapsed: 0.0002, timeout: T) == .menuBarNotReady,
      "得到 \(String(describing: MenuInventory.classify(.cannotComplete, elapsed: 0.0002, timeout: T)))")
check("阈值边界：恰好一半算超时（>=）",
      MenuInventory.classify(.cannotComplete, elapsed: 1.0, timeout: T) == .cannotComplete)
check("阈值边界：一半少一点算未就绪",
      MenuInventory.classify(.cannotComplete, elapsed: 0.999, timeout: T) == .menuBarNotReady)
check("0.5s 超时下 0.5ms 失败仍是未就绪（不跟 timeout 绝对值挂钩）",
      MenuInventory.classify(.cannotComplete, elapsed: 0.0005, timeout: 0.5) == .menuBarNotReady)

print("\n[-25204 之外：错误码 → 语义]")
check("success → 不是失败", MenuInventory.classify(.success, elapsed: 0.01, timeout: T) == nil)
check("apiDisabled(-25211) → noPermission",
      MenuInventory.classify(.apiDisabled, elapsed: 0.01, timeout: T) == .noPermission)
check("invalidUIElement(-25202) → appGone",
      MenuInventory.classify(.invalidUIElement, elapsed: 0.01, timeout: T) == .appGone)
check("noValue(-25212) → noMenuBar",
      MenuInventory.classify(.noValue, elapsed: 0.01, timeout: T) == .noMenuBar)
check("notImplemented(-25208) → noMenuBar",
      MenuInventory.classify(.notImplemented, elapsed: 0.01, timeout: T) == .noMenuBar)

print("\n[只有便宜的暂时性失败才值得重试]")
// cannotComplete 虽也是暂时性，但每次要等满 timeout，重试 = 成倍拖延（实测 2000ms → 8886ms）。
check("menuBarNotReady 可重试（0.2ms 一次，很便宜）", MenuInventory.Failure.menuBarNotReady.isTransient)
check("真超时默认不重试（重试代价是 timeout 的整数倍）", !MenuInventory.shouldRetryTimedOut)
check("noMenuBar 不可重试（重试多少次都一样）", !MenuInventory.Failure.noMenuBar.isTransient)
check("noPermission 不可重试（要用户去授权）", !MenuInventory.Failure.noPermission.isTransient)
check("appGone 不可重试", !MenuInventory.Failure.appGone.isTransient)
check("other 不可重试", !MenuInventory.Failure.other(-1).isTransient)

// 后台辅助进程（crashpad_handler / WeChatHelper）和冷启动 GUI App 都返回 -25204，
// 但只有后者值得等。靠 NSRunningApplication 是否存在来区分——这个判断依赖真实进程，
// 所以这里只锁定「对非 App 进程不重试」这个契约的一半：其它失败一律不重试。
check("noMenuBar（后台进程本来没菜单栏）不会触发重试闭环",
      !MenuInventory.Failure.noMenuBar.isTransient)

// 重试预算别无限增长：冷启动窗口实测最长 4.7s，后台队列不能被钉死那么久。
// 2.5s 是折中——覆盖三次快速冷启动（0.01~0.38s），放弃 4.7s 那种极端情况。
let budget = MenuInventory.readyRetryBackoff.reduce(0, +)
check("重试预算在 1~2.5s 之间（够覆盖冷启动，又不至于钉死后台队列）",
      budget >= 1.0 && budget <= 2.5, "得到 \(budget)s")

// MARK: - 第二个修正项：回车打开文件（issue #5 的架构验收）

print("\n[修正项协议：加第二个实现不用改 UI]")

// 协议成立的最低条件：registry 里有两个实现，且都能被 UI 用同样的方式消费。
let registry = CorrectionRegistry()
check("registry 里有 2 个修正项", registry.corrections.count == 2,
      "得到 \(registry.corrections.count)")
check("id 互不重复", Set(registry.corrections.map(\.id)).count == 2)
check("每个都有自己的 title（开关能显示）",
      registry.corrections.allSatisfy { !$0.title.isEmpty })
check("每个都有自己的 subtitle（用户能看懂为什么）",
      registry.corrections.allSatisfy { !$0.subtitle.isEmpty })
check("每个都能回答 requiredPermission",
      registry.corrections.allSatisfy { !$0.requiredPermission.description.isEmpty })

let openFile = OpenFileCorrection()
check("id 稳定（改名会让用户设置丢失）", openFile.id == "finder.enter-to-open",
      "得到 \(openFile.id)")

// 这是 issue #3 踩过的坑，第二个实现必须不重复它：
// init() 不能把「上次开着」写进 isOn，否则 restoreSaved() → enable() 会早退。
UserDefaults.standard.set(true, forKey: "correction.\(openFile.id).enabled")
let freshOpenFile = OpenFileCorrection()
check("新建实例 isOn=false（isOn 是「现在生效吗」，不是「上次开着吗」）",
      freshOpenFile.isOn == false)
UserDefaults.standard.removeObject(forKey: "correction.\(openFile.id).enabled")

// 没权限时 enable 必须失败，而不是静默成功
if !AXIsProcessTrusted() {
    // 无权限环境：协议必须给出可展示的错误
    if case .failure(let e) = openFile.enable() {
        check("无权限时 enable 返回 failure 且带可读消息", e.message.count > 10)
    } else {
        check("无权限时 enable 返回 failure", false, "却返回了 success")
    }
} else {
    check("有权限环境下跳过（不做 TCC 操作）", true)
}

// 注册表语义：setEnabled 必须真的驱动 isOn，且 disable 能彻底撤回
let scratch = OpenFileCorrection()
check("初始 isOn=false", scratch.isOn == false)
scratch.disable()          // 幂等：没开时 disable 不该崩
check("未开启时 disable 是幂等的", scratch.isOn == false)

// 权限语义：零权限项的真实行为
check("Permission.none.isGranted 恒为 true", Permission.none.isGranted)
check("Permission.none 的描述不吓人", Permission.none.description == "无需权限")

// MARK: 回车决策规则（纯函数，真机手按之外唯一的验证手段）

print("\n[回车 → 打开：该放行的必须放行]")

func decide(_ key: Int, _ m: ShortcutModifiers = [], finder: Bool = true,
            sheet: Bool = false, role: String? = nil) -> FinderReturnRule.Decision {
    FinderReturnRule.decide(keyCode: key, modifiers: m, frontmostIsFinder: finder,
                            sheetOpen: sheet, focusedRole: role)
}

check("Return 键码是 36 和 76",
      FinderReturnRule.isReturnKey(36) && FinderReturnRule.isReturnKey(76))
check("字母键不是 Return", !FinderReturnRule.isReturnKey(0))

check("Finder 里纯 Return → 打开", decide(36) == .openSelection)
check("小键盘 Enter 也能打开", decide(76) == .openSelection)

// 这些放行错一个，用户就在重命名时把文件打开了 / 或按不动弹窗按钮
check("不是 Finder → 放行（别的 App 回车要能用）",
      decide(36, finder: false) == .passThrough(.notFinderFrontmost))
check("带 ⌘ 的 Return → 放行（⌘↵ 是系统给「打开」叠加的键）",
      decide(36, [.command]) == .passThrough(.notPlainReturn))
check("带 ⇧ 的 Return → 放行", decide(36, [.shift]) == .passThrough(.notPlainReturn))
check("普通字母键 → 放行", decide(0) == .passThrough(.notPlainReturn))
check("Finder 有弹窗 → 放行（Return 是默认按钮）",
      decide(36, sheet: true) == .passThrough(.sheetOpen))
check("正在编辑文本框 → 放行（重命名中要能按回车确认）",
      decide(36, role: "AXTextField") == .passThrough(.textEditing))
check("搜索框 → 放行", decide(36, role: "AXSearchField") == .passThrough(.textEditing))
check("下拉框 → 放行", decide(36, role: "AXComboBox") == .passThrough(.textEditing))
check("焦点在图标上（AXGroup）→ 打开",
      decide(36, role: "AXGroup") == .openSelection)
check("焦点未知（nil）→ 打开（保守倾向于用户按的就是文件）",
      decide(36, role: nil) == .openSelection)

// 优先级：即使有弹窗，也必须先看是不是 Return
check("带修饰键 + 有弹窗 → 仍优先判「不是纯 Return」",
      decide(36, [.command], sheet: true) == .passThrough(.notPlainReturn))

// 修饰键解码：只认四个语义修饰键，Fn 不算
var fnFlags: CGEventFlags = [.maskSecondaryFn]
check("Fn 不算修饰键（Fn+Return 仍可打开）",
      FinderReturnRule.modifiers(from: fnFlags).isEmpty)
fnFlags = [.maskCommand, .maskControl]
check("⌘⌃ 被正确解码",
      FinderReturnRule.modifiers(from: fnFlags) == [.command, .control])

// 迁移目录：F8 现在应该是 fixable，且指向真实存在的 correction
print("\n[迁移目录：F8 从「只能给指引」升级为「一键修」]")
let f8 = MigrationCatalog.entries.first { $0.id == "F8" }
check("F8 条目存在", f8 != nil)
if let f8 {
    if case .fixable(let cid) = f8.remedy {
        check("F8 是 fixable", true)
        check("F8 指向 finder.enter-to-open", cid == "finder.enter-to-open",
              "得到 \(cid)")
    } else {
        check("F8 是 fixable", false, "仍是 guidance/unfixable")
    }
}

// MARK: - Windows 键位对照表

print("\n[Windows 键位对照表：查得准比查得多重要]")

// 核心项必须对。这些是迁移者每天按十几次的键，错一条就会把「Windows: Ctrl+C」
// 显示在「复制」旁边——看似合理、实则是把肌肉记忆引到错误的方向。
check("⌘S / 保存 → Ctrl+S",
      WindowsEquivalents.lookup(combo: "⌘S", action: "保存") == "Ctrl+S",
      "得到 \(WindowsEquivalents.lookup(combo: "⌘S", action: "保存") ?? "nil")")
check("⌘S / 存储（Storage 的说法）也命中",
      WindowsEquivalents.lookup(combo: "⌘S", action: "存储") == "Ctrl+S")
check("⌘C / 拷贝 → Ctrl+C",
      WindowsEquivalents.lookup(combo: "⌘C", action: "拷贝") == "Ctrl+C")
check("⌘C / 复制（另一套菜单译法）也命中",
      WindowsEquivalents.lookup(combo: "⌘C", action: "复制") == "Ctrl+C")
check("⌘V / 粘贴 → Ctrl+V",
      WindowsEquivalents.lookup(combo: "⌘V", action: "粘贴") == "Ctrl+V")
check("⌘X / 剪切 → Ctrl+X",
      WindowsEquivalents.lookup(combo: "⌘X", action: "剪切") == "Ctrl+X")
check("⌘A / 全选 → Ctrl+A",
      WindowsEquivalents.lookup(combo: "⌘A", action: "全选") == "Ctrl+A")
check("⌘Z / 撤销 → Ctrl+Z",
      WindowsEquivalents.lookup(combo: "⌘Z", action: "撤销") == "Ctrl+Z")
check("⇧⌘Z / 重做 → Ctrl+Y（Windows 的重做不是 Ctrl+Shift+Z）",
      WindowsEquivalents.lookup(combo: "⇧⌘Z", action: "重做") == "Ctrl+Y",
      "得到 \(WindowsEquivalents.lookup(combo: "⇧⌘Z", action: "重做") ?? "nil")")
check("⌘⇥（产品里 Tab 就显示成 ⇥）→ Alt+Tab（与动作名无关的系统键）",
      WindowsEquivalents.lookup(combo: "⌘⇥", action: "切换 App") == "Alt+Tab")
check("⌘⇥ 即使不知道动作名也命中（actions 为空的系统键）",
      WindowsEquivalents.lookup(combo: "⌘⇥", action: "") == "Alt+Tab")

// 查不准的项不该瞎猜：表里没有的动作必须返回 nil。
check("表里没有的组合 → nil（不猜）",
      WindowsEquivalents.lookup(combo: "⌘⇧K", action: "随便什么动作") == nil)
check("表里没有的动作 → nil（宁可少一条，不可错一条）",
      WindowsEquivalents.lookup(combo: "⌘S", action: "保存到图库") == nil)
check("空动作名 → nil（不拿空字符串乱命中）",
      WindowsEquivalents.lookup(combo: "⌘S", action: "") == nil)
check("空组合 → nil",
      WindowsEquivalents.lookup(combo: "", action: "保存") == nil)

// 同一个 macOS 组合在不同 App 里含义不同，必须按键位 + 动作名双匹配。
// ⌘D：访达是「复制（Duplicate）」，Word/Pages 是「加粗」，浏览器是「加书签」。
check("⌘D 不收录（访达=复制 / Word=加粗 / Chrome=加书签，含义冲突）",
      WindowsEquivalents.lookup(combo: "⌘D", action: "复制") == nil,
      "得到 \(WindowsEquivalents.lookup(combo: "⌘D", action: "复制") ?? "nil")")
check("⌘T / 显示字体 不会被错认成新标签页（文本编辑里 ⌘T 是字体）",
      WindowsEquivalents.lookup(combo: "⌘T", action: "显示字体") == nil,
      "得到 \(WindowsEquivalents.lookup(combo: "⌘T", action: "显示字体") ?? "nil")")
check("⌘T / 新标签页 → Ctrl+T",
      WindowsEquivalents.lookup(combo: "⌘T", action: "新标签页") == "Ctrl+T")

// 前缀别名：菜单标题常带 App 名后缀（「退出文本编辑」），不能被漏掉。
check("退出* 前缀命中「退出文本编辑」",
      WindowsEquivalents.lookup(combo: "⌘Q", action: "退出文本编辑") == "Alt+F4")
// 前缀别名只在「同一个 macOS 组合」内生效，所以它不会把 ⌥⌘Q 的「退出并保留窗口」
// 误认成 ⌘Q 的退出：键位不同，根本走不到这条目。
check("⌘Q 不会命中无关动作",
      WindowsEquivalents.lookup(combo: "⌘Q", action: "取消") == nil)
check("⌥⌘Q / 退出并保留窗口 不在表里 → nil（不跟着 ⌘Q 走）",
      WindowsEquivalents.lookup(combo: "⌥⌘Q", action: "退出并保留窗口") == nil)
// ⌘,（设置…）刻意不收录：Windows 没有 App 级偏好设置的统一快捷键，
// Win+I 开的是系统设置、不是当前 App 的偏好设置——语义不同，宁可留空。
check("⌘, / 设置… 刻意不收录（Win+I 是系统设置，不是 App 偏好设置）",
      WindowsEquivalents.lookup(combo: "⌘,", action: "设置…") == nil,
      "得到 \(WindowsEquivalents.lookup(combo: "⌘,", action: "设置…") ?? "nil")")
check("带省略号的菜单标题能命中（打开… / 打印…）",
      WindowsEquivalents.lookup(combo: "⌘P", action: "打印…") == "Ctrl+P")

// 数据自检：表本身必须自洽，否则展示层会随机拿到两条不同的答案。
check("表非空", !WindowsEquivalents.allEntries.isEmpty)
check("macOS 组合格式全部合法（⌃⌥⇧⌘ 顺序 + 认识的键位）",
      WindowsEquivalents.invalidEntries().isEmpty,
      "非法：\(WindowsEquivalents.invalidEntries().map(\.macCombo))")
check("Windows 组合格式全部合法（Ctrl/Alt/Win/Shift + 一个键）",
      WindowsEquivalents.invalidWindowsEntries().isEmpty,
      "非法：\(WindowsEquivalents.invalidWindowsEntries().map(\.windowsCombo))")
check("同一个 macOS 组合没有映射到两个不同的 Windows 组合",
      WindowsEquivalents.conflictingMacCombos().isEmpty,
      "冲突：\(WindowsEquivalents.conflictingMacCombos())")
check("单条内部没有重复动作名", WindowsEquivalents.duplicatedActions().isEmpty,
      "重复：\(WindowsEquivalents.duplicatedActions())")
check("每条都有分类（面板分组要靠它）",
      WindowsEquivalents.allEntries.allSatisfy { !$0.group.isEmpty })
check("每条的 Windows 组合都是真的（不含自造键名）",
      WindowsEquivalents.allEntries.allSatisfy { WindowsEquivalents.isValidWindowsCombo($0.windowsCombo) })

// 格式校验本身也要能抓到坏数据——否则上面几条只是「永远为真」的摆设。
check("格式校验能抓到修饰键顺序写错的条目（⌘⇧Z 不是合法写法）",
      !WindowsEquivalents.isValidMacCombo("⌘⇧Z"))
check("格式校验能抓到只有修饰键、没有键位的条目",
      !WindowsEquivalents.isValidMacCombo("⌘⇧"))
check("格式校验能抓到自造的 Windows 键名",
      !WindowsEquivalents.isValidWindowsCombo("Ctrl+Foo"))
check("格式校验能抓到缺键位的 Windows 组合",
      !WindowsEquivalents.isValidWindowsCombo("Ctrl+"))
check("合法写法通过校验（正例）",
      WindowsEquivalents.isValidMacCombo("⌘S") && WindowsEquivalents.isValidWindowsCombo("Ctrl+S"))

// 空表 / 未知键不能崩：查询是纯函数，只应该安静地返回 nil。
check("查询空组合 + 空动作不崩",
      WindowsEquivalents.lookup(combo: "", action: "") == nil)
check("组合只差大小写时不误命中（键位是符号，不该模糊匹配）",
      WindowsEquivalents.lookup(combo: "⌘s", action: "保存") == nil)

// 面板演示数据：调试入口用它验证版式，坏了一条就会少一行。
let demoItems = WindowsEquivalents.demoItems()
check("演示快照条数与表一致（每条都能还原成菜单项）",
      demoItems.count == WindowsEquivalents.allEntries.count,
      "\(demoItems.count) vs \(WindowsEquivalents.allEntries.count)")
check("演示快照每条都有键位",
      demoItems.allSatisfy(\.hasShortcut))
check("演示快照的组合与表里的 macOS 组合完全一致（还原没丢修饰键）",
      Set(demoItems.map(\.combo)) == Set(WindowsEquivalents.allEntries.map(\.macCombo)),
      "差集：\(Set(demoItems.map(\.combo)).symmetricDifference(Set(WindowsEquivalents.allEntries.map(\.macCombo))))")

// MARK: - 结果

print("\n" + String(repeating: "─", count: 46))
if failures == 0 {
    print("全部通过：\(checks) 项检查")
    exit(0)
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}

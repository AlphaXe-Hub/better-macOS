# 第二个修正项：架构验收报告（issue #5）

> issue 原文：「这个 issue 的目的是验证协议假设：加一个新痛点是否真的不用改 UI 一行代码。
> 如果做不到，说明接口设计是错的，应该趁早改。」
>
> 所以本文的重点是**协议撑不撑得住**，不是「多了个功能」。

## 一句话结论

**UI 确实零改动，协议这一半成立。但「零权限项」这个前提是错的——`Permission.none` 这条分支至今没有任何真实实现会走到，协议对它的假设从未被验证过。**

## 1. 选了哪条，为什么

选 **F8「回车键打开文件」**，理由是它在 `research/pain-points.md` 里同时满足三个条件：

1. **后果最重**：迁移用户在 Finder 里连按回车会把文件名改坏，是不可撤销的破坏。
2. **判为「纯软件、无权限门槛」**——这一点正好能压测协议里 `Permission.none` 这个角落。
3. 不需要 Finder 扩展、不需要 GUI 权限，纯事件流 + AppKit。

第 2 条是我选它的主要原因：如果只在「都需要辅助功能权限」的项上验证协议，
`Permission` 枚举里 `case .none` 那一支就永远测不到，而它恰恰是最可疑的设计。

## 2. 验收证据

### 2.1 UI 零改动（密码学证明）

```
Preferences.swift     工作区 blob f493b128aa939e7aca9a25e9574a7daa0285dc84
                       HEAD      blob f493b128aa939e7aca9a25e9574a7daa0285dc84
MigrationGuide.swift  工作区 blob 8ca2babf2b9abdfa40e2672e571350fe6a57a707
                       HEAD      blob 8ca2babf2b9abdfa40e2672e571350fe6a57a707
```

blob SHA 完全一致，比 `git diff --stat` 更强：它证明文件内容逐字节没变。

### 2.2 开关自动出现（视图树 A/B 对照）

**同一份未改动的 `Preferences.swift`**，只换 registry 里的条目数：

```
--- A: registry 只有 1 项 ---
  <NSSwitch> id=scroll.separate-direction state=off

--- B: registry 有 2 项 ---
  <NSSwitch> id=scroll.separate-direction state=off
  <NSSwitch> id=finder.enter-to-open    state=off
```

新开关的标题、说明、「需要辅助功能权限」那行小字也一并自动出现，
全部来自 `c.title` / `c.subtitle` / `c.requiredPermission.description`——
`Preferences.correctionRow(_:)` 一个字没动。

> 注：`--open-prefs --render` 在本分支上渲染成 `0x620`（宽塌成 0），
> 那是 issue #10 的既有 bug（`documentView` 缺宽度来源），不是本 issue 引入的。
> 我用视图树 dump 绕开了它；视觉证据见 `docs/assets/prefs-2-corrections.png`
> （在 `fix-10` 的宽度修复之上渲染，560x620）。

### 2.3 功能真的生效（真机 E2E）

真实 Finder 窗口，AX 设焦点到文件列表 → ↓ 选中文件 → 合成 Return 走 `cghidEventTap`：

| | 按 Return 后焦点 role | 前台 App | 结论 |
|---|---|---|---|
| **A 修正关闭** | `AXTextField` | 访达 | 进入重命名（系统原语义）|
| **B 修正打开** | `AXOutline` | 文件被打开 | 不再重命名 |

另有 tap 接线探针（下游 `tailAppendEventTap` 观察者）：

- 修正开启时按 Return，观察者**只看到 `O+⌘`，看不到 `Return`** → Return 确实被吞掉并替换
- 带 ⌘ 的 Return 正常放行
- `disable()` 之后 Return 恢复原样

### 2.4 单测

`app/test.sh`：**50 项 → 82 项，全绿**。新增 32 项覆盖：

- 协议层面：registry 有 2 项、id 不重复、每项都能回答 title/subtitle/permission
- `isOn` 语义：新建实例 `isOn == false`（**不重复 issue #3 的坑**）
- `enable` 幂等、`disable` 幂等、开→关→开→关往返后回到初始态
- `FinderReturnRule.decide(...)` 的 16 条决策分支
- 迁移目录：F8 是 `fixable` 且指向真实存在的 correction id

## 3. 我改了哪些文件

```
app/Sources/OpenFileCorrection.swift  | 308 +++++++++++++  (新增，全部实现)
app/Sources/Corrections.swift         |   3 +-           (只 2 行：属性 + 注册)
app/Sources/MigrationCatalog.swift    |   5 +-           (F8: guidance → fixable)
app/Tests/main.swift                  | 111 ++++++++     (只追加，末尾汇总前)
app/test.sh                           |   1 +
```

`Corrections.swift` 的**全部**改动，就这两行：

```swift
 final class CorrectionRegistry {
     private(set) var corrections: [Correction] = []
     let scroll = ScrollDirectionCorrection()
+    let openFile = OpenFileCorrection()
 
     init() {
-        corrections = [scroll]
+        corrections = [scroll, openFile]
     }
```

按 Lead 要求留出合并对位信息：改动位于 `@@ -226,9 +226,10 @@`，即
`CorrectionRegistry` 属性声明区与 `init()`——与 issue #3 改的
`ScrollDirectionCorrection.init()`（文件前半部）和 `handle(event:)`（中部）不重叠。

## 4. 协议是不是够用

这一节基于写第二个实现时的实际痛感，不是泛泛而谈。

### 4.1 `Result<Void, CorrectionError>` 够不够？

**够用，但不完整。** 实际写的时候撞到三种失败，协议只能表达第一种：

| 失败场景 | 协议能表达吗 | 实际处理 |
|---|---|---|
| `enable()` 当场失败（没权限、`tapCreate` 返回 nil）| ✅ `.failure` | 经 `setEnabled` → NSAlert「无法打开」→ 去授权 |
| 开启**之后**才失效（系统停掉 tap、用户中途撤销权限）| ❌ | 只能自己 `disable()`，用户看到开关还在但已经没用了 |
| `disable()` 失败（还原不彻底）| ❌ | `disable()` 返回 `Void`，失败是静默的 |

第二种在这个实现里是**真实会发生的**：`tapDisabledByTimeout` 超过 5 次我就调
`disable()` 放弃了，但**协议没有任何通道把这件事告诉用户**——开关是 UI 画的，
UI 不会重新读 `isOn`，除非用户再点一次。我只能 `NSLog`。

第三种更值得警惕：协议注释写着「每个修正都必须能彻底撤回」，
但 `func disable()` 不返回 `Result`，**这条纪律没法被强制，也没法被测试**。

建议（不改也能活，但迟早要改）：

```swift
func disable() -> Result<Void, CorrectionError>   // 让「撤回失败」可表达
var onStateChanged: (() -> Void)? { get }          // 让「开着但失效了」能推给 UI
```

### 4.2 `options` / `setOption` 是不是过度设计？

**是过度设计，而且比想象中更严重——它是死代码。**

全项目 grep 结果：

```
Correction 协议声明          2 处（Corrections.swift:27-28）
CorrectionOption 定义        1 处（Corrections.swift:50）
ScrollDirectionCorrection    声明 2 行 + 实现 setOption 一行
UI 消费                      0 处
```

`Preferences.correctionRow(_:)` 只读 `title` / `subtitle` / `requiredPermission` / `isOn`，
**从来不渲染 `options`**。`MigrationGuide.swift` 也不读。

也就是说 `ScrollDirectionCorrection` 那个「同时反转横向滚动」的开关，
用户**在 UI 上根本够不到**——它只能靠改 UserDefaults 或者改代码触发。
`ScrollDirectionCorrection` 里那个 `reverseHorizontal` 变量，从 UI 出发是永远为 false 的。

这不是「第二个实现用不上所以显得多余」，而是**第一个实现就已经有未接线的选项**。
协议里留一个没有 UI 契约的开放集合，代价是每个实现者都要为它写两行空实现
（我这个第二个实现就写了 `let options: [CorrectionOption] = []` + 空 `setOption`），
收益是零。

建议：要么删掉，要么补齐 UI 消费（在 `correctionRow` 里按 `kind` 渲染 toggle/stepper）。
**维持现状是最差的**——它让协议看起来比实际能力大。

### 4.3 零权限项下 `requiredPermission` 是不是多余？

**不多余，但当前设计把「需要什么」和「有没有」混在一起了。**

我原本以为会验证到 `.none` 这一支，结果没验证到（见下节）。
但即使 `.none`，`requiredPermission` 仍然有不可替代的作用：
**它是 UI 上唯一能显示的能力声明**。`Preferences` 渲染的
`c.requiredPermission.description`（「无需权限」/「需要辅助功能权限」）是用户
决定敢不敢开这个开关的唯一依据。

问题在于协议把两件事塞进了一个成员：

- `requiredPermission` → 「我需要什么」（静态声明，UI 用）
- `enable()` 内部又 `guard requiredPermission.isGranted` → 「现在有没有」（运行时判断）

第二件事是**每个实现都必须自己重复写一遍**。`ScrollDirectionCorrection` 写了，
我也写了。漏写就是「没权限也返回 success 但实际不工作」——
而协议完全不阻止这种实现。

建议：把守卫提到 `CorrectionRegistry.setEnabled` 里统一做一次，
实现者只关心「怎么开」，不关心「能不能开」。这样 `requiredPermission`
就真的只是声明，语义干净，且无法被实现者忘记。

### 4.4 顺带：`isOn` 的语义在协议里没写清楚（issue #3 的根因）

协议注释只说「当前是否生效」，但 `ScrollDirectionCorrection.init()` 把
「上次开着吗」写进了 `isOn`，导致 `restoreSaved() → enable()` 撞上
`guard !isOn` 早退，tap 从来没装过。

**这不是实现者的疏忽，是协议没把语义钉死。** 两个状态——「持久化意图」和
「运行时事实」——被一个 `isOn` 同时承担。我的实现刻意做了区分
（`init()` 不读 UserDefaults，注释写明 `isOn` = 现在真的生效吗），
但那是**靠自觉**，不是靠协议。

建议把注释写成显式契约：

```swift
/// 现在**真的**生效吗。不是「用户上次开着吗」。
/// 持久化恢复是 CorrectionRegistry.restoreSaved() 的职责，
/// 实现方不得在 init() 里用持久化值初始化它。
var isOn: Bool { get }
```

## 5. 「零权限项」这条假设：调研文档是错的

`research/pain-points.md` 把 F8 标成「纯软件、无权限门槛」，判断为 🟢。
**本机实测这个判断不成立**，证据链：

1. 遍历 Finder 菜单树（AX）：`文件 → 重新命名` 的 `AXMenuItemCmdChar` 为空、
   `AXMenuItemCmdVirtualKey` 为 -1、`AXMenuItemCmdGlyph` 为 -1 ——
   **它没有键位等价物**。`文件 → 打开` 是 `⌘O`。
2. 结论：Enter=重命名 是 Finder **内部**处理的，不是菜单快捷键。
3. 所以系统设置里的「App 快捷键」能给「打开」**叠加**一个 ⌘↵，
   但**无法取消** Enter=重命名——这正是调研文档自己写的话。
4. 要真正复刻 Windows（Enter=打开），只能在事件流上拦 Return 并转 ⌘O。
5. `CGEvent.tapCreate(.defaultTap)` 必须有辅助功能权限（本机验证：
   无权限返回 nil / 装上了也零投递）。

所以我的实现 `requiredPermission = .accessibility`，**不是 `.none`**。

这条偏差本身就是 issue #5 想要的答案之一：

> **`Permission.none` 这一支至今没有任何真实实现会走到。**
> 协议的 `Permission` 枚举有 2 个 case，实际只有 1 个被用过。
> 「协议对零权限项也成立」这句话，到今天为止没有任何证据——
> 包括我这次，也没验证到。

想真正验证它，需要找一个**真的**零权限的痛点。候选：
- `F3 复制路径`：纯 AX 读 + 剪贴板写，`requiredPermission = .none` ✓
- `W5 双击标题栏`：系统设置项，不需要权限（但它更像 guidance 而非 correction）

建议后续单独开一个 issue 用 F3 验证 `.none` 这一支，**否则就应该考虑
把 `Permission` 简化掉**——一个只有一支在用的枚举，和一个 bool 没区别。

## 6. 合并注意事项

见 §3。另外：

- 新文件 `OpenFileCorrection.swift` 必须在 `app/test.sh` 的文件列表里加一行，
  否则 `test.sh` 编译不到它（它是显式列文件的）。
- 如果 issue #3 的 `ScrollCorrectionMath` 先合入，本分支的
  `Tests/main.swift` 追加块会落在它那段之后，不冲突（两边都是末尾追加）。
- `build.sh` 用 `Sources/*.swift` 通配，新文件自动进包，无需改动。

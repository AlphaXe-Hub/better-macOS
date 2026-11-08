# #6 / #8 结论：Electron 系菜单读取 + 权限引导的边界

> 环境：macOS 26.4 (25E246) / arm64 / Swift 6.3.3 / CLT-only。
> 本文每条结论都有本机实测数据，探针代码在 [`scripts/ax-probe/`](../scripts/ax-probe/)。

## 一句话结论

**#6 不是「微信不支持」，也不是「超时」——是一个错误码背了两种含义，我们只认了其中一种。**

`-25204 cannotComplete` 同时用来表示：

| 耗时 | 真实含义 | 该怎么做 |
|---|---|---|
| ≈ messaging timeout（实测 2005ms / 2.0s） | App 真的忙/卡住 | 等（但别反复重试，每次都要再等满 timeout） |
| 0.1~0.3ms | App 的菜单栏**还没建好**（冷启动），或这进程根本不是 GUI App | 稍等再读，或直接当「没有菜单」 |

旧代码把两者都当 `cannotComplete`，于是冷启动时的「还没好」被记成了故障，
并且那次失败**不会自己重试**——这就是 issue 里 `SNAPSHOT-FAIL 微信` 的来源。

## 探针数据

### 稳态：所有 App 都能读到，0 失败

`./scripts/ax-probe/run.sh --n 10 --timeouts 0.5,2,5`

| App | timeout | 成功/总 | avg | max | topLevel |
|---|---|---|---|---|---|
| 微信 | 0.5s / 2s / 5s | 10/10 全部 | 1.8 / 0.2 / 0.3ms | 16.7ms | 7 |
| Obsidian | 0.5s / 2s / 5s | 10/10 全部 | 1.1 / 0.2 / 0.2ms | 8.7ms | 9 |
| Chrome | 0.5s / 2s / 5s | 10/10 全部 | 1.1 / 0.1 / 0.2ms | 9.9ms | 11 |

**timeout 取值对稳态毫无影响**——因为它们根本没接近超时。这本身就否掉了
「2 秒不够、要调大」这个假设。

> ⚠️ 探针从终端跑，`AXIsProcessTrusted()` 返回 true（继承终端授权，见 README）。
> 所以上表是「最大授权」状态。它的价值是把**权限**这个变量排除掉：
> 既然探针能读到，微信的菜单就不是「读不到」，而是特定时刻读不到。

### 冷启动：真正的失败模式在这里

飞书（`com.bytedance.macos.feishu`）冷启动，50ms 一次采样：

| 试验 | 不可读窗口 | 窗口内每次耗时 | 之后 |
|---|---|---|---|
| 首次初始化 | **4.67s** | 0.1~0.5ms | 永久成功 |
| 第 2 次 | 0.36s | 0.2~0.3ms | 永久成功 |
| 第 3 次 | 0.38s | 0.2~0.3ms | 永久成功 |
| 第 4 次 | 0.01s | — | 立刻就成功了 |

**关键观察**：不可读期间每次都是 `-25204`，但**耗时 0.1~0.5ms**。
不是超时。App 只是还没把菜单栏搭起来。

同一时刻 `err=0` 出现后，`topLevel` 立刻就是 5~6 个菜单，说明菜单是**一次性建成**的。

### 对照实验：真超时长什么样

`kill -STOP <pid>` 冻结微信主进程（模拟「App 卡死」），再读：

| timeout | err | 耗时 | 判读 |
|---|---|---|---|
| 0.5s | -25204 | 515.5ms | 超时指纹（103%） |
| 2.0s | -25204 | 2005.0ms | 超时指纹（100%） |
| 5.0s | -25204 | 5001.6ms | 超时指纹（100%） |

同一个 `-25204`，耗时差 **一万倍**。这就是判据。

### 顺带发现：非 GUI 进程也是这个码

| 进程 | `NSRunningApplication` | err | 耗时 |
|---|---|---|---|
| 微信主进程 | 存在 | 0 | 17ms |
| `crashpad_handler` | **nil** | -25204 | 0.1ms |
| `WeChatHelper` | **nil** | -25204 | 0.1ms |
| `WeChatAppEx`（accessory） | 存在 | 0 | 已读到头 |

所以 `-25204` 快速返回有**两个来源**：冷启动中的 GUI App、和压根不是 App 的辅助进程。
前者值得等，后者等多久都没用——用 `NSRunningApplication` 是否存在就能分开。

### 另一个隐藏坑：messaging timeout 不继承

`AXUIElementSetMessagingTimeout(appEl, 2.0)` **只对 appEl 生效，子元素拿不到**：

| 设置 | 读子元素（目标已 SIGSTOP）耗时 |
|---|---|
| 只在 appEl 上设 0.5s | **1500ms**（= 全局默认值） |
| 用 `AXUIElementCreateSystemWide()` 设 0.5s | **503ms** |

不设全局超时，App 在「读到菜单栏之后、遍历没结束」时卡住，
就是 1.5s × 菜单项数量 累加——200 项的 App 能把后台队列钉死好几分钟。

## #6 三问的答案

### 1) 微信有几个进程？前台激活的是哪个？

**14 个**（本机实测）。Electron 系一个 App 拉一窝：

| pid | 角色 | activationPolicy |
|---|---|---|
| 91969 | **`WeChat` 主进程** | `regular` ← 前台激活的是这个 |
| 91971 | `crashpad_handler` | 不是 NSRunningApplication |
| 91975 | `WeChatAppEx` | `accessory` |
| 91977 | `WeChatAppEx Helper` | 不是 NSRunningApplication |
| 91978 | `WeChatAppEx Helper (GPU)` | 不是 NSRunningApplication |
| 92019 | `WeChatHelper`（wxocr） | 不是 NSRunningApplication |
| 92020 | `WeChatAppEx Helper` | 不是 NSRunningApplication |
| 92021 | `WeChatHelper`（wxutility） | 不是 NSRunningApplication |
| 92022 | `XPlayer` | `accessory` |
| 92023/92024/92025/92029 | 渲染器 ×4 | `accessory` |
| 92031 | `WeApp` | `accessory` |

**结论：必须读 `regular` 那个（91969）。** 读错了（比如按名字取到 helper）
就会拿到 `-25204` 并误判成「微信不支持」。
`NSWorkspace.frontmostApplication` 恰好总是给主进程，所以产品路径是对的。

### 2) `-25204 cannotComplete` 是超时还是真的不支持？

**都不是，也不是同一个东西。** 它有两种：

- 冷启动未就绪：0.1~0.5ms 返回，**不是超时**，等它就好；
- 真忙：恰好耗时 = timeout，是超时。

改 timeout 值（0.5/2/5s）对冷启动那一类**完全没用**——它 0.2ms 就返回了，
你设 500 秒也一样失败。对真忙那一类，调大 timeout 只是让它等更久。

**所以「调大 timeout」是一个错误的方向**，实测数据直接否掉了它。

### 3) 飞书、Obsidian 表现是否一致？

**一致。** 三个 Electron App 稳态都 10/10 成功、耗时都在 1ms 量级；
飞书冷启动和微信是**同一个模式**（快速 `-25204` → 就绪 → 永久成功）。
Obsidian （`md.obsidian`）4 个进程、微信 14 个、飞书 5 个——进程结构不同，
但 AX 层的表现完全一样。

> VS Code 本机未安装，用 Obsidian 替代（issue 原文允许）。

## 改了什么

### `app/Sources/MenuInventory.swift`

1. **按耗时拆分 `-25204`**（核心修复）
   - 新增 `Failure.menuBarNotReady`（快速失败 = 冷启动/非 App 进程）
   - `cannotComplete` 语义收窄为「真等到超时」
   - `classify(_:elapsed:timeout:)` 是**纯函数**，可单测，阈值 `timeout × 0.5`
2. **重试只给便宜且会自己好的那种**
   - `menuBarNotReady` 且 `NSRunningApplication` 存在 → 退避重试 0.15/0.3/0.6/1.0s
   - `cannotComplete` **不重试**（见下面的踩坑）
   - `noMenuBar` / `noPermission` / `appGone` 不重试
3. **补上全局 messaging timeout**（1.0s），解决子元素不继承导致的长时间卡死

### `app/Sources/PermissionGuide.swift`（#8 第 3 条 + 窗口重叠，全在本文件内）

1. **轮询改为「只在状态变化时重排 UI」**——原来每秒无条件重建一次 label/约束，
   窗口会持续闪烁。
2. **`RunLoop.main.add(timer, forMode: .common)`**——默认模式（`.default`）的
   timer 在拖动窗口、打开菜单时会停摆。（同一个坑 `FrontmostAppTracker` 已踩过。）
3. **增加 `NSApplication.didBecomeActiveNotification` 即时检查**——
   把「用户从系统设置切回来」到「状态刷新」的空窗从最多 1 秒压到 0。
4. **窗口避免重叠**：`present()` 时枚举屏幕上已有窗口，在候选位置里选**重叠最小**的
   （不写死「右边」，窄屏上右边放不下）。

**重叠修到什么程度（实测，同尺寸邻居窗口 620×672 居中）**：

| 屏幕 | 重叠 |
|---|---|
| 1920×1080 | **0%** ✓ |
| 2560×1440 | **0%** ✓ |
| 3440×1440 超宽 | **0%** ✓ |
| 1470×923（本机 13"） | 99.5% → **15.9%**（暴力网格验证为**全局最优**）|
| 1024×768 | 几何下限（两侧剩 202pt < 引导宽 560pt）|

**必须说清的限制**：1470 宽的屏幕上，620 宽的窗口居中后两侧各剩 425pt，
而引导窗口最窄 560pt —— **几何上不存在完全不重叠的位置**。
15.9% 已经是该屏幕的理论最优（暴力枚举验证）。

**真正的根治需要改 `AppDelegate.swift`（不在我的写域）**，只需 3 行：

```swift
// AppDelegate.swift 第 60-65 行，把「同时开两个窗口」改成「先只开引导」
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    self.openPermissionGuide()          // 未授权时先解决权限，别开清单
    // 清单等授权后再由 openPermissionGuide 的 onGranted 打开
}
```

配套：把 `openGuide()` 挂到 `PermissionGuideWindow.onGranted` 上
（`openPermissionGuide()` 里已有 `w.onGranted = { self.tracker.refresh() }`，
再加一行 `self.openGuide()` 即可）。**这需要 Lead 合并，我没动那个文件。**

## 没改什么，以及为什么

| 没做 | 原因 |
|---|---|
| 不调大 timeout | 数据直接否掉：冷启动那类 0.2ms 就返回，设 500s 也没用 |
| 不对 `cannotComplete` 重试 | **踩过坑**：早先版本重试 4 次，卡死场景从 2000ms 恶化到 **8886ms** |
| 不给非 GUI 进程重试 | `NSRunningApplication` 为 nil 的进程没有菜单栏是正常的，不该让用户等 |
| 不动 `AppDelegate.swift` / `Preferences.swift` / `HUDWindow.swift` / `Corrections.swift` | 别人的写域 |
| 不改 `-25204` 的 enum case 名 | `AppDelegate.swift` 里 `case .cannotComplete:` 还在（已改成收窄语义，能编译）|

## 修复前后对比（实测）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 飞书冷启动 → 读到菜单 | 0.17s 就放弃（`cannotComplete`），**要等下一次切 App 才有机会** | 0.84s / 1.15s **直接读到**（items=41）|
| 微信稳态 | OK 62 项 | OK 62 项（无回归）|
| 微信卡死（SIGSTOP） | 2000ms → `cannotComplete` | 2013ms → `cannotComplete`（**无恶化**）|
| 非 GUI 辅助进程 | 163ms → `cannotComplete` | **5ms** → `menuBarNotReady`（变快 32 倍）|
| App 端到端（切飞书冷启动） | `SNAPSHOT-FAIL` | `SNAPSHOT 飞书 items=41`，无失败行 |
| 引导窗口 vs 清单窗口（13"） | 99.5% 重叠 | 15.9%（几何最优）|
| 引导窗口 vs 清单窗口（≥1920 宽）| 99.5% | **0%** |

单元测试：**50 → 69 项全部通过**。

## #8 的边界结论

### 能在本机验证的（已验）

| 项 | 结论 |
|---|---|
| 轮询在系统设置为前台时会不会漏检 | **不会漏检**，但会有最多 1 秒延迟。已加 `didBecomeActive` 即时检查把延迟压到 0 |
| 两个窗口重叠 | 已修至「宽屏 0%、窄屏几何最优」，根治需改 AppDelegate（见上） |

> 「打开系统设置 → 授权 → 切回来」这条链路，本次**没有真人操作验证**
> （自动化点不进系统设置的 TCC 面板）。代码层面的结论是：
> timer 在 `.common` 模式跑，系统设置成为前台**不会**让我们的 timer 停；
> 加上 `didBecomeActive` 兜底，**逻辑上不会漏检**。但请把这条放进下方手测清单。

### 本机不可能验证的（必须人手做）

见下节。

## 待人手验证清单

> 下面三条**本机不可能自动验证**：系统设置的 TCC 面板不接受合成事件，
> 且需要多台不同 macOS 版本的机器。**不要把它们当成已验证。**

### A. 拖拽是否在 macOS 14 / 15 / 26 都被系统设置接受

**步骤**（每个版本各做一次）：

1. 先清掉旧授权：`tccutil reset Accessibility dev.better-mac.app`
2. 打开 App：`open app/build/better-macOS.app`
3. 等引导窗口出现，点「打开系统设置」→ 应跳到「隐私与安全性 → 辅助功能」
4. **按住引导窗口里那个 App 图标，拖到系统设置的列表里松手**
5. 观察列表里有没有出现 `better-macOS`
6. 切回引导窗口，看状态是否变成「已经可以用了」

**预期**：第 5 步列表里出现 App；第 6 步 ≤1 秒变绿。

**要记录**：系统设置的辅助功能面板**是否接受这次拖拽**。
- macOS 26：预期接受
- macOS 15 / 14：**未验证**，尤其注意 Sonoma 时代该面板曾对拖拽来源有更严的要求
- 如果系统设置**拒绝**（图标弹回、列表无变化）→ 记下版本号，这是需要改用「＋ 号」路径的信号

### B. 用 `＋` 号选择 App 时路径是否同样有效

**步骤**：

1. 同 A 的第 1-3 步（走到辅助功能面板）
2. 点列表下方的 **`＋`**
3. 在文件选择器里按 `⇧⌘G`，粘贴 App 路径：
   `<仓库>/app/build/better-macOS.app`
4. 选中 → 打开
5. 看列表里是否出现 `better-macOS`，开关是否可打开
6. 切回引导窗口看状态

**预期**：与拖拽路径等效。

**为什么要单独验**：`＋` 号走的是 `NSOpenPanel`，它按 **bundle** 校验签名。
ad-hoc 签名（没有 `setup-devcert.sh`）的 App 可能在这里被静默拒绝，
而拖拽路径不经过这层校验。**这正是引导文案里说「拖拽唯一可靠」的原因**——
如果 B 通过，那句文案可以放宽；如果不通过，证明文案是对的。

### C. 授权状态轮询在「系统设置是前台」时会不会漏检

**步骤**：

1. 未授权状态打开 App，让引导窗口停在那儿
2. 点「打开系统设置」，**不要**切回引导窗口，让系统设置保持前台
3. 在系统设置里把 `better-macOS` 的开关打开
4. **系统设置仍在前台**，用眼睛看（或先截图）引导窗口的状态行
5. 再切回引导窗口

**预期**：第 4 步状态行就应变成「已授权」；第 5 步切回来时已经不需要等待。

**要记录**：如果第 4 步仍显示「未授权」、第 5 步才变 → `didBecomeActive` 兜底在
该版本上没生效，需要把 poll 间隔从 1.0s 调小。

## 复现本文所有数据

```bash
# 稳态画像
./scripts/ax-probe/run.sh --n 10 --timeouts 0.5,2,5

# 冷启动画像（另开一个终端）
pkill -f "飞书.app/Contents/MacOS"; sleep 3
open -a /Applications/飞书.app
./scripts/ax-probe/run.sh --app 飞书 --n 5

# 真超时对照（SIGSTOP 模拟卡死）
kill -STOP $(pgrep -f "微信.app/Contents/MacOS/WeChat" | head -1)
./scripts/ax-probe/run.sh --app 微信 --n 3 --timeouts 0.5,2,5
kill -CONT $(pgrep -f "微信.app/Contents/MacOS/WeChat" | head -1)

# 单元测试
./app/test.sh
```

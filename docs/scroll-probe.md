# issue #3 取证：滚动方向分离在真实鼠标上未生效

> 状态：**根因已定位并修复；真实设备字段仍待人手验证**（见 §4）。
> 本机：macOS 26.4 / Apple Silicon / CLT-only 构建。

## 1. 怎么跑探针（可复现命令）

探针是 `app/Sources/ScrollProbe.swift`，由 `main.swift` 的 `--probe-scroll` 触发，
外面包了一层 `app/probe-scroll.sh`（负责构建 + 提示授权）。

```bash
# 打包（必须产出 .app：TCC 的辅助功能授权是按「签名身份 + bundle」记的，
# 裸二进制的 cdhash 每次都变，授权永远对不上）
./app/build.sh debug

# A. 真实设备采集（必须有人用真手去滚，否则 0 事件）
./app/probe-scroll.sh 15

# B. 合成事件：只验证字段通路与判据分支，**不能**代替 A
./app/probe-scroll.sh --exercise 8

# C. 端到端翻转验证：不碰人手，验证「装了 tap 的进程到底改没改事件」
#    原理：本进程在 .tailAppendEventTap（队尾）只读监听，
#    better-macOS 的修正 tap 在 .headInsertEventTap（队首）——
#    同一事件先被 App 改、再被我们看见。
./app/probe-scroll.sh --verify-flip
./app/probe-scroll.sh --verify-flip --enable-tap   # 探针自己装一次产品的 tap 做对照
```

前置条件（三个模式都要求）：

1. `AXIsProcessTrusted = true`（探针自己会打印，false 就直接告诉你）
2. 跑的是 `app/build/better-macOS.app` 里的二进制，不是 `swiftc -o /tmp/x` 的裸二进制
3. `--exercise` / `--verify-flip` 还额外需要 `CGPreflightPostEventAccess = true`

探针打印的字段（一次一行）：

```text
[  0.01s] #1  cont=0 d1=+1 d2=+0 p1=+10 p2=+0 f1=+1.00 f2=+0.00
              phase=0 mom=0 count=0 instant=0 srcPID=5230 srcUD=0
              senderID=nil → 翻转(判据=滚轮)
```

对应 `CGEventTypes.h` 的原始编号，探针里全部按编号读，不依赖 Swift 侧剥前缀后的名字：

| 探针字段 | 字段 | 编号 | 含义 |
|---|---|---|---|
| `cont` | `kCGScrollWheelEventIsContinuous` | 88 | **现行判据**：非 0 = 连续（像素）= 触控板 |
| `d1`/`d2` | `kCGScrollWheelEventDeltaAxis1/2` | 11/12 | 行/格增量 |
| `p1`/`p2` | `kCGScrollWheelEventPointDeltaAxis1/2` | 96/97 | 像素增量 |
| `f1`/`f2` | `kCGScrollWheelEventFixedPtDeltaAxis1/2` | 93/94 | 16.16 定点增量 |
| `phase` | `kCGScrollWheelEventScrollPhase` | 99 | 手势阶段（只有手势设备带） |
| `mom` | `kCGScrollWheelEventMomentumPhase` | 123 | 惯性阶段（只有手势设备带） |
| `srcPID` | `kCGEventSourceUnixProcessID` | 41 | 合成事件 = 投递者的 pid；真实硬件 = 0 |
| `srcUD` | `kCGEventSourceUserData` | 42 | 同上 |
| `senderID` | `IOHIDEventGetSenderID`（SPI） | — | 真实硬件事件才有；合成事件为 nil |

## 2. A 节：合成事件验证（逻辑分支）

**这一节只证明「代码按它以为的规则在工作」，不证明真实设备是什么样。**

```
$ ./app/probe-scroll.sh --exercise 5

AXIsProcessTrusted    = true
CGPreflightPostEvent  = true
IOHID SPI             = 可用（senderID 可读）
模式                  = 合成事件（只验证字段通路与分支）

→ 投递 离散（滚轮语义，行单位）：期望 cont=0
[  0.01s] #1  cont=0 d1=+1 p1=+10 f1=+1.00 phase=0 mom=0 srcPID=5230 senderID=nil → 翻转(判据=滚轮)
→ 投递 连续（触控板语义，像素单位）：期望 cont=1
[  0.26s] #2  cont=1 d1=+1 p1=+1  f1=+0.10 phase=0 mom=0 srcPID=5230 senderID=nil → 放行(判据=触控板)

事件总数 = 2
  cont=0: 1 个 → 现行判据判定「滚轮：翻转」 | phase=[0] momentum=[0] srcPID=[5230] senderID=nil
  cont=1: 1 个 → 现行判据判定「触控板：原样放行」 | phase=[0] momentum=[0] srcPID=[5230] senderID=nil
```

结论（A 节）：

- `getIntegerValueField(.scrollWheelEventIsContinuous)` 读写通路正常，`cont=0` 走翻转、`cont=1` 走放行，**二分判据的分支实现是对的**。
- 翻转确实同步改了 `d1`/`p1`/`f1` 三组（上例 `--verify-flip` 里 `+3 → -3`、`+24 → -24`、`+3.00 → -3.00`）。
- **合成事件里 `phase`/`momentum` 恒为 0、`senderID` 恒为 nil**，所以「用 phase 或 senderID 替代 IsContinuous」这条路，
  合成事件**验证不了**，只能靠真实设备数据。这是 A 节的天花板，写清楚比含糊过去强。

端到端翻转验证（A 节的加强版，仍属合成）：

```
$ ./app/probe-scroll.sh --verify-flip

投递前（合成）：cont=0 d1=+3 p1=+24 f1=+3.00
队尾观察到 1 个事件：
  cont=0 d1=-3 p1=-24 f1=-3.00 → 翻转(判据=滚轮)

✓ d1 从 +3 变成 -3 —— App 的 tap **确实在投递并改写**事件。
```

## 3. B 节：根因定位（不需人手，已有确凿证据）

在等真实设备数据之前，先从日志链路上发现了**比判据更前置的问题**：

```
$ grep -n 'SCROLL\|restored' ~/Library/Logs/better-macOS.log
（空 —— 一条都没有）

$ defaults read dev.better-mac.app
{ "correction.scroll.separate-direction.enabled" = 1; "perm.prompted" = 1; }
```

开关在 defaults 里明明是 `1`（用户打开过），但日志里 `SCROLL correction ON (tap installed)` 一次都没出现。
手工把 defaults 改成 `YES` 再 `open` 那个 .app，把二进制直接拖起来看 stderr：

```
$ ./app/build/better-macOS.app/Contents/MacOS/better-macOS   # 前台直跑才能看到 NSLog
[better-macOS] restored correction: scroll.separate-direction     ← restoreSaved() 认为成功了
（没有 [better-macOS] scroll correction ON）                        ← 但 enable() 的装机代码一行没跑
```

读代码就明白了（修复前）：

```swift
init()  { isOn = Self.wasEnabled }                    // ① 启动时把「上次开着」直接当「现在生效」
enable() { guard !isOn else { return .success(()) } } // ② 于是 restoreSaved() 调的 enable() 立刻早退
                                                       //    后面的 tapCreate / CFRunLoopAddSource 全跳过
```

`CorrectionRegistry.restoreSaved()` 只从 `UserDefaults` 取「应该开吗」，随后调 `enable()`；
它把 `.success(())` 当成「装好了」，日志里就写下 `restored correction`。
但 `enable()` 因为 `isOn` 在 `init()` 里已经是 `true`，第一行的 guard 就返回了。

**结果：开关在 UI 上亮着、defaults 里也是 `1`、日志还写着 `restored`，tap 却从未安装。**
这正好解释 issue 的两条观察——「开了但没效果」和「日志里一条 SCROLL 记录都没有」。

### 验证这个根因

```bash
# 修复前：只有 restored，没有 ON
./app/build/better-macOS.app/Contents/MacOS/better-macOS 2>&1 | grep -E 'restored|scroll correction'

# 修复后：两行都有，顺序是 ON 先、restored 后
# [better-macOS] scroll correction ON
# [better-macOS] restored correction: scroll.separate-direction
```

修复后再用队尾探针验证整条链（App 用 `open` 启动，让 responsible process 是 App 自己）：

```bash
defaults write dev.better-mac.app "correction.scroll.separate-direction.enabled" -bool YES
open app/build/better-macOS.app && sleep 3
./app/probe-scroll.sh --verify-flip
```

修复后的实际输出：

```
投递前（合成）：cont=0 d1=+3 p1=+24 f1=+3.00
队尾观察到 1 个事件：
  cont=0 d1=-3 p1=-24 f1=-3.00 → 翻转(判据=滚轮)
✓ d1 从 +3 变成 -3 —— App 的 tap 确实在投递并改写事件。
```

> ⚠️ 启动方式有坑：用 `nohup ./…/Contents/MacOS/better-macOS &` 从 shell 拉起时，
> TCC 的 responsible process 会归到 shell 上，App 拿不到那份授权，
> 表现同样是「tapCreate 成功但零投递」。**验证一律用 `open` 启动。**

## 4. B 节：真实设备数据（待人手补）

**这一节目前是空的，因为只有人手真的滚了才有数据。** 我自己合成的 scrollWheel 事件
`srcPID` = 探针自己的 pid、`senderID` = nil，它证明不了 BT5.4 Mouse 的真实字段。

需要用户做的事（约 10 秒）：

```bash
./app/probe-scroll.sh 15
```

15 秒内：

1. 在 **BT5.4 Mouse** 上滚 3 秒（向上滚一次、再向下滚一次）
2. 在 **触控板** 上滚 3 秒（同样两个方向，并等惯性滚完）
3. 剩下的时间不用动

把输出贴回来（或者让我从 `app/build/` 里再读）。要填的表：

| 设备 | cont | d1 | p1 | f1 | phase | mom | srcPID | senderID |
|---|---|---|---|---|---|---|---|---|
| BT5.4 Mouse（滚轮） | 待测 | | | | | | | |
| Apple Internal Keyboard / Trackpad | 待测 | | | | | | | |

**关键问题：真实滚轮的 `cont` 是 0 还是 1？**

- 若是 `0`：现行判据正确，issue 的现象由 §3 的根因解释，已修。
- 若是 `1`：判据本身错误，得换判据（优先用 `phase`/`momentum`，实在不行才上 SPI `senderID`）。
- 若是「只有部分鼠标是 1」（外接离散滚轮和 Magic Mouse 混用）：二分判据本质上不够，
  必须走设备级判别（`senderID` 或 `IOHIDEventSystemClient` + 设备数据库）。

本机已确认存在的外设（`system_profiler SPBluetoothDataType`）：

```
BT5.4 Mouse:  Minor Type: Mouse, Services: BLE     ← 带滚轮的蓝牙鼠标
Wanderfree@Lofree:  Minor Type: Keyboard           ← 蓝牙键盘
Apple Internal Keyboard / Trackpad                 ← 触控板
```

## 5. `senderID` 这条退路（已实测可用）

issue 里说「如果是 1，得改 IOHID 源判别（会引入 SPI）」。我先把 SP 可行性探掉了：

| 符号 | 结果 |
|---|---|
| `CGEventCopyIOHIDEvent` | 可 `dlsym` |
| `IOHIDEventGetSenderID` | 可 `dlsym` |
| `IOHIDEventGetIntegerValueField` | **不存在**（别照抄旧博客） |
| `IOHIDEventGetType` / `IOHIDEventGetFloatValue` | 可 `dlsym` |

探针里 `senderID` 已经接上了（`dlsym` 拿不到就静默降级成 `nil`，不崩）：

- **合成事件**：`CGEventCopyIOHIDEvent` 返回 nil → `senderID=nil`
- **真实 HID 事件**：能读到非 0 的 senderID（本机实测见到过 `0x100007f61`）

所以「按具体设备区分」在本机技术上可行，但它需要一张 `senderID → 设备` 的映射表，
而且 `CGEventCopyIOHIDEvent` 是 SPI（App Store 不可用、未来系统可能变），
**只有 §4 证明二分判据不够时才值得上**。

## 6. 判据是否正确的判断

分三层，别混：

1. **判据的分支实现** —— 正确。`cont=0 → 翻转`、`cont=1 → 放行`，合成事件与端到端验证都过了（§2）。
2. **判据在真实设备上的语义** —— **未验证**（§4）。`IsContinuous` 的官方注释是
   「像素基 = 非 0、行基 = 0」，它描述的是**数据形态**，不是**设备类型**。
   这两件事在多数设备上重合，但**不是同一个问题**——如果哪只滚轮鼠标上报像素级数据，判据就会判错。
3. **issue 描述的现象** —— 已由 §3 的根因解释（tap 从未安装），与判据无关。

## 7. 已做的修复

改动都局限在 `app/Sources/Corrections.swift` 的 `init()` / `handle(event:)`，以及新增的纯函数类型；
没有动 `Preferences.swift` / `HUDWindow.swift` / `AppDelegate.swift` 的 `handleKey`。

1. **`init()` 不再 `isOn = Self.wasEnabled`**。
   `isOn` 的语义收紧为「tap 此刻装上了吗」，「上次开着吗」只由 `restoreSaved()` 消费。
   这是 issue #3 的直接根因。
2. **判据与翻转抽成 `ScrollCorrectionMath`（纯函数）**。
   埋在 event tap 回调里的分支除了真机手滚没有验证手段；抽出来后 `app/test.sh` 能覆盖。
   `handle(event:)` 现在只剩三行接线。
3. **自测从 50 项加到 64 项**（`app/test.sh` 全绿），新增断言锁住：
   - 新建修正项 `isOn` 必须是 `false`（防 root cause 回归）
   - `cont=0` 时三组 delta 都被取反
   - `cont=1` 时**一个字段都不许动**（含 `phase`/`momentum`）
   - 判据读的确实是 field 88

## 8. 剩余不确定性（诚实清单）

- **真实滚轮的 `cont` 仍未实测**（§4）。所以「判据在本机所有设备上都对」这句话现在还不能说。
- 本机**只此一台**，`BT5.4 Mouse` 一种滚轮设备。别的鼠标（尤其罗技/雷蛇带平滑滚轮驱动的）
  很可能上报 `cont=1`，那是另一个 issue，需要设备级判别。
- **`~/Library/Logs/better-macOS.log` 在我的执行环境里写不进去**
  （`Operation not permitted`，shell 沙箱拦住 `~/Library/Logs`）。
  所以 §3 的证据一律走「前台直跑二进制看 stderr」而非 Diag 日志。
  在正常 App 里 Diag 是工作的（历史上日志有几千行）。
- `Diag.log` 每次写都开关一次文件句柄，在事件热路径上不该调——这次没改（不在 issue 范围），
  但值得单独开一个。

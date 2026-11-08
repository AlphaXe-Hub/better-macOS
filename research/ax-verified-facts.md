# AX / 菜单 / 事件 —— 本机实机验证事实清单

> 环境：macOS 26.4 (25E246) / arm64 / Swift 6.3.3 / 仅 Command Line Tools。
> 本文只写**我在本机亲手跑出来**的东西：每条都给命令或源码，每条都可复现。
> 标 **未验证** 的，是我这轮没跑通、需要 TCC 授权或被沙箱挡住的部分，**不是结论**。
> 方案全景、竞品、分发路线见 [tech-feasibility.md](./tech-feasibility.md)，本文不重复。

## 0. 五条硬结论

1. **`kAXMenuItemSelectedNotification` 真实存在**，SDK 头文件可查，这是「观察菜单触发」方案的地基（§1）。
2. **跨进程读菜单要 Accessibility；读自己进程的菜单完全不需要授权**（`err=0`），且**必须打成 `.app` 跑**——裸 CLI 可执行文件会返回 `-25208 NotImplemented`（§2）。
3. **AX 的 `AXEnabled` 属性不可信**：App 明确 `isEnabled=false` 的菜单项，AX 仍报 `enabled=1`。别拿它做置灰判断（§3）。
4. **`kAXMenuItemCmdModifiers` 是 Carbon 位掩码且 `⌘` 隐含**：`mods=0` 就是「只有 ⌘」，无修饰键是 `8`（`NoCommand`）。本机用三种菜单项逐一核对通过（§4）。
5. **键盘 CGEventTap 未授权必然 `nil`；`scrollWheel` 的 listen-only 能建、`.defaultTap` 不能**——即「改滚动」必须拿 Accessibility（§5）。

---

## 1. 菜单触发相关 AX 通知：SDK 里确实有

```bash
SDK=$(xcrun --show-sdk-path)
grep -n "kAXMenuOpenedNotification\|kAXMenuClosedNotification\|kAXMenuItemSelectedNotification\|kAXSelectedChildrenChangedNotification" \
  "$SDK/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXNotificationConstants.h"
```

实测输出（行号为真实值）：

| 行号 | 常量 | 字符串值 |
|---|---|---|
| 213 | `kAXMenuOpenedNotification` | `AXMenuOpened` |
| 220 | `kAXMenuClosedNotification` | `AXMenuClosed` |
| **227** | **`kAXMenuItemSelectedNotification`** | **`AXMenuItemSelected`** |
| 279 | `kAXSelectedChildrenChangedNotification` | `AXSelectedChildrenChanged` |

→ 「AXObserver 观察菜单被触发」这条路线的**常量名不是猜的**，SDK 自带。语义为「值是被选中的那个菜单项 UIElement」。

**注册也能成功**（本机实测，自读进程）：`AXObserverCreate(pid, cb, &obs)` 返回 `0`，四个通知 `AXObserverAddNotification` **全部返回 `0`**（`-25209` 才是重复注册、`-25207` 才是 unsupported）→ 「能不能注册」不构成障碍。

**未验证**：通知触发时回调是否 fire。本机程序化触发菜单动作收到 `fired=0`，但这**不能证明通知不 work**——程序化触发不经过系统菜单跟踪路径，须**真人手点/真按键**；跨 App 观察又需 Accessibility。**这是 v1 第一优先级实测项**（有授权后 5 分钟可验）。

## 2. 自读菜单：不需要授权，但必须是 `.app`

| 包装方式 | `kAXMenuBar` 结果 |
|---|---|
| 裸 CLI 可执行文件（`swiftc` 直出，非 bundle） | **`-25208` `kAXErrorNotImplemented`** |
| 打成 `.app`（手写 Info.plist + `codesign -s -`） | **`0`（成功）** |

`.app` 形态下**即使 `AXIsProcessTrusted()==false` 也读成功**，层级完整：

```
role=AXMenuBarItem title=File
  role=AXMenu  title=<nil>
    role=AXMenuItem title=Save  char=S mods=0 enabled=1
```

**跨进程（未授权）实测**：`AXUIElementCreateApplication(pid1)` 与另一普通进程，读 `kAXMenuBar` 均返回 **`-25204` `kAXErrorCannotComplete`**（不是 `-25211`）。
→ 实践中**别只判 `-25211`**，未授权时更常见的是 `-25204`。完整码表见 `AXError.h`（`0` / `-25200…-25214`）。

> 复现要点：`swiftc` **必须显式带 `-target arm64-apple-macos14.0`**，否则撞 arm64e slice 的 SDK/编译器版本不匹配；沙箱下默认 ModuleCache 不可写，需 `-module-cache-path ./mc`。

## 3. `AXEnabled` 不可信（重要陷阱）

构造 `Paste` 项并显式 `paste.isEnabled = false`：

| 菜单项 | App 自己的 `isEnabled` | AX 报的 `enabled` |
|---|---|---|
| Save | `true` | `1` |
| **Paste** | **`false`** | **`1` ← 撒谎** |
| Plain | `true` | `1` |

→ **不能拿 `kAXEnabledAttribute` 判断可否执行**。自读时用 `NSMenuItem.isEnabled`；跨进程只能**放弃置灰**或「点了再看效果」。KeyStruck 说的「不可执行项变灰」在跨 App 场景靠 AX 做不到，**这点需与 lead 对齐预期**。

## 4. `kAXMenuItemCmdModifiers` 解码（已用真实菜单项核对）

SDK `AXAttributeConstants.h` 的 `AXMenuItemModifiers` 枚举原文：`None=0 /* no modifiers other than the command key (which is used by default) */`、`Shift=1<<0`、`Option=1<<1`、`Control=1<<2`、`NoCommand=1<<3`。

实测三组对照（左为 `NSMenuItem.keyEquivalentModifierMask.rawValue`，右为 AX 读到的 `mods`）：

| 菜单项 | 真实 mask | AX `mods` | 正确解读 |
|---|---|---|---|
| Save | `1179648` (0x120000 = ⌘+⇧) | `1` | ⌘⇧（**⌘ 隐含**，只多出 shift） |
| Paste | `1048576` (0x100000 = ⌘) | `0` | 纯 ⌘ |
| Plain | `0`（无修饰键） | `8` | **`NoCommand`：连 ⌘ 都没有** |

→ 规则：**`mods` 的所有位都不含 ⌘；`0` 意味着「⌘ 单独」；要「无修饰键」得看 bit3(`8`)**。`kAXMenuItemCmdVirtualKey` / `CmdGlyph` 在本机自读场景下**返回 nil**（非 ASCII 键才可能有值），所以主键位应以 `CmdChar` 为准，`VirtualKey` 只作补充。

## 5. CGEventTap 权限矩阵（未授权进程，逐一建 tap）

| 事件类型 | options | tap 位置 | 结果 |
|---|---|---|---|
| `keyDown` | listenOnly | session | **NIL** |
| `keyDown` | default | session | **NIL** |
| `flagsChanged` | listenOnly | session | OK |
| `scrollWheel` | listenOnly | session | OK |
| `scrollWheel` | **default** | session | **NIL** |
| `scrollWheel` | **default** | **hid** | **NIL** |

同时测得的授权状态：`AXIsProcessTrusted()=false`、`AXIsProcessTrustedWithOptions(prompt:false)=false`、`CGPreflightListenEventAccess()=false`、`CGPreflightPostEventAccess()=false`。

**读法**：**键盘要 Input Monitoring**（keyDown 无论如何都 nil）；`flagsChanged` 反而能收 → 未授权下**纯靠 flagsChanged 判「⌘ 按下/松开」可行**，但单击/双击仍需另一路信号。**改滚动要 Accessibility**（`.defaultTap` 在 session/hid 两处都 nil），换 tap 位置绕不过去；listen-only 只能看不能改。
**未验证**：授权后这些 NIL 是否变 OK（需 TCC，本机无法验证）。

## 6. 其他本机确认项

| 项 | 命令 | 结果 |
|---|---|---|
| 代码签名身份 | `security find-identity -v -p codesigning` | **0 valid identities** |
| 滚动方向偏好 | `defaults read -g com.apple.swipescrolldirection` | **`0`** |
| 是否有设备级覆盖 | `defaults -currentHost read -g com.apple.swipescrolldirection` | **该键不存在** → 方向是全局单键，**无设备级开关可读**，分离只能在事件流上做 |
| 系统符号热键条数 | `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys` | **21 条** |
| 无授权时 osascript 访问 System Events | `osascript -e 'tell application "System Events" to get name of first process'` | **报错 `-10004`（权限违例）** |

**滚动判别信号**（`CGEventTypes.h` 公开声明）：`kCGScrollWheelEventIsContinuous=88`、`kCGScrollWheelEventMomentumPhase=123`、`kCGScrollWheelEventScrollPhase=99`、`kCGEventSourceUnixProcessID=41`。
**SPI 确认**：`CGEventCopyIOHIDEvent` 在公开 SDK 头文件**查无声明**——
```bash
grep -rn "CGEventCopyIOHIDEvent" "$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreGraphics.framework/Headers/"
# 无输出，exit=1
```
→ 想按「具体是哪只鼠标」区分必须用 SPI；只做「滚轮 vs 触控板」二分**只读 `IsContinuous` 就够，无需 SPI**。

## 7. 结论边界

- **不需要任何授权就能做**：自读自己菜单（仅 `.app` 形态）、构建/签名/打包全链路、读全局偏好与 `AppleSymbolicHotKeys`。
- **必须拿 Accessibility 才能继续验证**：跨 App 读菜单、`AXMenuItemSelected` 是否真 fire、`.defaultTap` 改滚动事件。
- **本轮明确没验**（留给有权限环境）：Chromium/微信/飞书的 AX 菜单暴露度、系统级快捷键能否进 AX 通知、双击 ⌘ 的纯 AX 路径、滚动反向后 momentum 是否受损。
- **踩过的坑**：`swiftc` 不带 `-target arm64-apple-macos14.0` 必失败；沙箱内必须 `-module-cache-path`；裸 CLI 读菜单 `-25208`；未授权跨进程是 `-25204` 不是 `-25211`。

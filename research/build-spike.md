# 构建可行性 spike：CLT-only / 无证书 / 无 AX 授权下的 macOS 菜单栏 App

> 环境：macOS 26.4 (25E246) arm64 M5，`swiftc` 6.3.3，SDK 26.5，**无 Xcode.app**（`xcodebuild` 报 `requires Xcode`），**0 签名证书**，**AX 未授权**（`AXIsProcessTrusted()=false`）。工程与原始日志：`/tmp/bmac-spike`（`verify.sh` 一键复跑，18/18 PASS）。

## 0. 结论先行

**能。** 六项能力全部在本机跑通，均不需 Xcode.app 或付费证书：

1. `swiftc` 手工组装 .app → `open` 启动，`lsappinfo` 报 `type="UIElement"`，无 Dock 图标 ✓
2. `NSStatusItem` 常驻菜单栏（SF Symbol + `isTemplate`）✓
3. `NSPanel` `.borderless+.nonactivatingPanel`、`level=.floating`、毛玻璃、1.5 s 淡出 ✓，**实测不抢前台焦点**
4. 全局键盘监听两种写法**未授权时都不报错**，这是最大的坑（见 4）
5. 跨 App 读菜单栏**需要** AX 授权（`-25211`）；但**读自己**不需要，可借此验证遍历代码与属性格式
6. ad-hoc 签名**必需**（未签名 arm64 无法启动），但**不需要证书**；`SMAppService` 在 ad-hoc 下可注册

**取舍**：技术栈可行，成败不在构建而在 **TCC 授权引导**——未授权时的表现是「图标在、按什么都没反应」的静默失败。

## 1. 构建链：CLT-only 可行，两个环境陷阱

`xcodebuild` 彻底不可用；`swiftc` 完全可用。`build.sh`：`swiftc -O -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos14.0 -framework AppKit` + 手写 plist。必需四键：`CFBundleExecutable`、`CFBundleIdentifier`、`LSUIElement=true`、`NSPrincipalClass=NSApplication`。`CFBundleExecutable` 指向的文件缺失时 `open` 报 `The application cannot be opened because its executable is missing.`（exit 1）；`plutil -lint` 只验语法（该坏 plist 仍报 `OK`），**不能替代真机启动测试**。

两个陷阱（**仅本沙箱环境**，但会误导判断）：① 默认 clang module cache 不可写 → `Operation not permitted` 并附带**误导性的** `this SDK is not supported by the compiler`（**不是** SDK 版本问题，加 `-module-cache-path` 即解决）；② SwiftPM 的 `sandbox-exec` 无法嵌套 → `swift build --disable-sandbox` + `CLANG_MODULE_CACHE_PATH` 后正常。

## 2. 菜单栏常驻

`NSStatusItem` + `NSImage(systemSymbolName:)`，`isTemplate=true` 自动适配明暗。`setActivationPolicy(.accessory)` **且** plist 写 `LSUIElement=true`（双保险）；日志确认 `activationPolicy=1` / `type="UIElement"`。

## 3. HUD 浮窗：「不抢焦点」要拆成两件事

规格：`.borderless+.nonactivatingPanel`、`level=.floating`（rawValue 3）、`backgroundColor=.clear`、`isOpaque=false`、`NSVisualEffectView(.hudWindow)` 圆角 22、`orderFrontRegardless()`。Window Server 独立枚举证实 `layer=3 alpha=1 onscreen=1`，淡出后 `alpha=0`；`hud.png` 为离屏渲染（无需录屏权限）。

**焦点实测**（面板显示期间，外部旁观进程每 100 ms 轮询前台 App）：

- `orderFrontRegardless()` → `isKeyWindow=false`，前台仍是 Chrome → **完全不打扰**。
- 若需接收键盘而要 `canBecomeKey`：`borderless` 恒为 **false**，加 `.titled` 后为 **true**。
- `.titled+.nonactivatingPanel` + `makeKey()` 后 `NSApp.isActive` 变 true、`isKeyWindow=true`，但**外部观察到的前台 App 始终是 Chrome**。即「拿到 key window」与「夺走系统前台」是两个层面。
- **未验证**：此时前台 App 的按键是否被截走（需真实按键+授权）。产品若做命令面板，**必须真机复验**。

## 4. 全局键盘监听：未授权时「静默失败」，别被返回值骗了

`AXIsProcessTrusted()=false`、`CGPreflightListenEventAccess()=false` 下实测：

| 写法 | 返回值 | 实际投递 |
|---|---|---|
| `CGEvent.tapCreate(.listenOnly, mask=keyDown)` | **nil** | 无 |
| `CGEvent.tapCreate(mask=flagsChanged/mouseMoved/scrollWheel)` | 非 nil，`tapEnable` 也成功 | **0 条** |
| `CGEvent.tapCreate(mask=keyDown+mouseMoved)` | **非 nil（迷惑项！）** | 0 条（键盘收不到） |
| `NSEvent.addGlobalMonitorForEvents(.keyDown)` | **非 nil（静默装上）** | **0 条** |
| `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` | 非 nil | **正常**（30 s 收 472 条） |

**`tapCreate`/`addGlobalMonitor` 返回非 nil 不等于能收到事件**；键盘与鼠标在 TCC 里门槛不同。唯一可靠判据是**计数实际投递**（`src/tapcount.swift`、`src/passive.swift`）或直接读权限状态。

授权检测实测值：`AXIsProcessTrusted()`→false；`AXIsProcessTrustedWithOptions(prompt:false)`→false（不弹窗，可安全轮询）；`CGPreflight{Listen,Post}EventAccess()`→false；`IOHIDCheckAccess` **初始 `2(Unknown)`，请求过一次后变 `1(Denied)`**——「Unknown」是「还没问过」，不能当「未授权」用。
主动请求均被自动拒绝：`CGRequestListenEventAccess`/`CGRequestPostEventAccess`/`IOHIDRequestAccess` 全返回 false；`prompt:true` 返回 false 且**未**拉起系统设置（系统设置进程启动早于探测器 44 分钟，已排除）。
**推断（未验证）**：这些失败来自沙箱无法完成 TCC 交互；正常用户双击应能看到弹窗，**必须真机点一次确认**。

## 5. 读取前台 App 菜单栏（Accessibility）

跨 App 读取（Chrome pid 1276、Finder pid 685）一律 `kAXMenuBarAttribute` → **`-25211 (apiDisabled)`**，0 行，3–6 ms；Safari 未运行。

**绕过方式（无需授权）**：App 读**自己**的 AX 树是允许的。`src/axself.swift` 完整走通 `AXUIElementCreateApplication(pid)` → `kAXMenuBarAttribute`（`err=0`）→ 递归 `kAXChildrenAttribute` → 读属性，拿到 3 个 `AXMenuBarItem`、18 个节点。

由此确认的属性格式（**对实现最关键**）：

- `kAXTitleAttribute`：字符串，无快捷键时为 `""`。
- `kAXMenuItemCmdCharAttribute`：**单个大写字符**（`H` `Q` `S` `O` `T` `Z` `,`），与输入大小写无关，**比较时必须 `uppercased()`**。
- `kAXMenuItemCmdModifiersAttribute`：`Int` 位标志。`0`=仅⌘，`1`=⌘⇧，`2`=⌘⌥，`12`=**⌃⌥**。
  规则：`bit0=Shift`、`bit1=Option`、`bit2=Control`、**`bit3 置位表示「无 Command」`**。
- `kAXEnabledAttribute`：菜单未显示时全为 false，**不可**作为「是否可执行」的业务判断依据。

## 6. 打包：ad-hoc 是硬门槛，证书不是

| 签名 | quarantine | `open` | 结果 |
|---|---|---|---|
| 未签名 | 无 | rc=1 | **无法启动**：`RBSRequestErrorDomain Code=5` / `NSPOSIXErrorDomain Code=163 "Launchd job spawn failed"` |
| 未签名 | 有 | rc=1 | 无法启动（同上） |
| ad-hoc | 无 | rc=0 | **正常启动** |
| ad-hoc | 有 | rc=0 | **被 Gatekeeper 拦截**（静默失败，无弹窗无输出） |

- **arm64 必须签名**，`codesign --force --deep --sign -` 即可（`Signature=adhoc`、`TeamIdentifier=not set`）；**无需证书、无需公证**。
- `spctl -a -vvv -t exec` 对 ad-hoc 一律 `rejected`（exit 3）——**本机照常运行**，因本地构建无 quarantine 标记。只有「从网上下载」的 ad-hoc 包会被拦。
- ad-hoc 的 DR 是 **`cdhash H"..."`**，改一个字符重建就变（实测 `85d9f71…`→`23c4776…`）。**TCC 授权会随每次重建失效**，开发期需预期反复授权，上线前必须换 Developer ID。
- **Sparkle**：更新签名是 **EdDSA(ed25519)**（`generate_keys`/`sign_update`），与 Apple 证书无关，无证书下可工作。**未跑端到端更新**（需发版）。
- **`SMAppService.mainApp`**：ad-hoc 下 `status` 由 `notFound(3)` → `register()` 成功 → `enabled(1)` → `unregister()` 成功，**不需证书**。`sfltool dumpbtm` 本机挂起，未能二次确认。

## 7. 体积与启动

| 项 | 数值 |
|---|---|
| `-O` 二进制 | 163,984 B（`strip -x` 后 134,400 B）；整包 172 KB |
| `-Onone` 二进制 | 227,560 B |
| 最小 AppKit 空壳 | 34,264 B |
| spawn → 菜单栏就绪 | **中位 73 ms**（`-O`，6 次热启动；冷启动首跑 592 ms） |
| `time open Foo.app` | 0.02–0.03 s（`open` 只投递给 launchd，**非真实冷启动耗时**） |

`-O` 相对 `-Onone`：体积小 28%，启动无可测差异（73 vs 73 ms，AppKit 初始化占主导）。**建议用 `-O`**。`time open` 不适合衡量启动，应用内打时间戳才准。

## 8. 未授权下无法确定的结论

1. 跨 App 真实菜单条数/格式：Safari（未运行）、Chrome/Finder（`-25211`）。**Chromium 系是否完整暴露 AX 菜单未知。**
2. 授权后按键监听真实投递率；`kAXMenuItemSelectedNotification` 跨 App 能否收到（自读时注册到 menu bar/AXMenu/AXApplication 均 `err=0`，但注册到 `AXMenuItem` 返回 **`-25207 notificationUnsupported`**；程序化 `AXPress` 触发 **0 条通知**——暗示该通知可能只在真用户点菜单时才发，**未验证**）。
3. 权限弹窗的真实表现（本机请求被自动拒绝且未拉起系统设置）。
4. `.titled+.nonactivatingPanel` 拿 key 后，前台 App 按键是否被截走。

**授权后按此顺序复跑**：

```bash
# 1) 系统设置 → 隐私与安全性 → 辅助功能 / 输入监控，勾选 build/BmacSpike.app
# 2) 确认状态翻转（应打印 true / 0）
open -n /tmp/bmac-spike/build/BmacSpike.app && sleep 8
# 3) 看跨 App 菜单与事件投递（期望 err=0、rows>0、withKeyEquiv>0；按住 ⌘⇧4 等后 keys>0）
grep -E "AX com\.|CGEventTap keys|NSEventGlobal keys" "$TMPDIR/bmac-spike.log"
# 4) 重跑事件矩阵与 AX 自读对照
cd /tmp/bmac-spike && ./verify.sh
```

**给产品的三条硬建议**：① 授权检测不能只看 API 返回值，要**计数实际事件**；② ad-hoc 下 cdhash 每次变、TCC 反复失效，开发期需预留重新授权流程，上线必须上 Developer ID；③ 首启必须主动引导授权，否则用户看到的是「图标在、但什么都不发生」的静默失败。
---

*关联 `keystruck-teardown.md` 第 6 节开放问题 2「AX 观察菜单触发的通知是什么」：本 spike 已把**注册侧**验证到 `AXObserverAddNotification` 层级，**触发侧仍需授权后复验**。*

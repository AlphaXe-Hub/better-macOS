# Windows 转 Mac 辅助工具 · macOS 技术可行性报告

> 环境：macOS 26.4 (25E246) / Apple Silicon / 仅 Command Line Tools（无 Xcode.app）。
> 标「本机实测」者已在机器上编译运行验证；标「未证实」者是查不到一手来源或无法验证。

## 0. 结论先行

1. **能力 B（列前台 App 快捷键）最稳**：AX 的 `kAXMenuBarAttribute` 递归菜单树，只读、不注入、不改事件，**只需 Accessibility 一项权限**。
2. **能力 A 可行，但"感知按键"与"知道动作"是两条路**：`AXObserver` 观察 `AXMenuItemSelected` 能拿动作名且**不需要 Input Monitoring**（KeyStruck 即此做法）；CGEventTap 只给键码，语义还得自己回查菜单树。
3. **能力 C 可行，且是三块里唯一"必须改事件"的**：需 `.defaultTap` 的 CGEventTap（**Accessibility**）；靠 `kCGScrollWheelEventIsContinuous` 就能干净地只动鼠标、不碰触控板惯性。
4. **App Store 基本封死**：Apple DTS 明确「受 Accessibility 管控的 API 与 App Sandbox 不兼容」，MAS 强制沙箱 → A/B/C 全在红线外。走官网直发 + Developer ID + 公证。
5. **没有 Xcode.app 也能做菜单栏 App**（本机已跑通），三个硬坑：`Bundle.module` 路径、ad-hoc 签名致 TCC 每次重编译失效、Sparkle 需手工嵌 Framework + rpath。

---

## 1. 读取前台 App 的菜单快捷键

### 1.1 NSMenu vs Accessibility API

| | `NSMenu` / `NSApplication.mainMenu` | `AXUIElement` + `kAXMenuBarAttribute` |
|---|---|---|
| 范围 | **只有自己进程**的菜单栏 | **任意前台进程**的菜单栏 |
| 拿到 | `keyEquivalent` + `keyEquivalentModifierMask` | `AXMenuItemCmdChar`/`CmdVirtualKey`/`CmdGlyph`/`CmdModifiers` + `AXTitle` |
| 权限 | 无 | Accessibility |

`mainMenu` 是 per-process 属性（[NSApplication.h](https://developer.apple.com/documentation/appkit/nsapplication/mainmenu)），只能给自己加菜单，**做不了跨 App 读取**。

AX 属性定义见 SDK `AXAttributeConstants.h`（[kAXMenuBarAttribute](https://developer.apple.com/documentation/applicationservices/kaxmenubarattribute)）。**修饰键是老的 Carbon 位掩码，不是 `NSEvent.ModifierFlags`**：`none=0`（**⌘ 隐含**）、`shift=1`、`option=2`、`control=4`、`noCommand=8`。SDK 原文：`kAXMenuItemModifierNone = 0 /* Mask for no modifiers other than the command key (which is used by default) */`（[kAXMenuItemCmdModifiersAttribute](https://developer.apple.com/documentation/applicationservices/kaxmenuitemcmdmodifiersattribute)）。忘了 bit3 会把所有快捷键读成带 ⌘；`12` 实际是「⌃ 单独」。

### 1.2 哪些 App 拿不到

判据是「**它有没有往系统菜单栏放 NSMenu**」，不是「是否原生」：

- **Chromium / Electron 有原生菜单栏 → 拿得到。** `chrome/browser/ui/cocoa/main_menu_builder.mm` 构造真实 `NSMenuItem` 并设 `keyEquivalent`/`keyEquivalentModifierMask`（[源码](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/cocoa/main_menu_builder.mm)）；Electron 文档：`Under macOS, these will be native menus.`（[menu.md](https://github.com/electron/electron/blob/main/docs/api/menu.md)）
- **Java（Swing 默认菜单栏）也拿得到。** OpenJDK `CMenuBar.m` 直接操作 `[NSApp mainMenu]` 与 `NSMenuItem`（[源码](https://github.com/openjdk/jdk/blob/master/src/java.desktop/macosx/native/libawt_lwawt/awt/CMenuBar.m)）
- **真拿不到**：自绘菜单 / 不用 NSMenu 的跨平台 UI；`LSUIElement` 后台 App（无菜单栏）；全屏游戏；**Carbon `RegisterEventHotKey` 全局热键**；App 内部自处理的按键；**系统级快捷键**（macOS 在 App 之前拦截）。后三条为 KeyStruck 官方自陈边界（[docs](https://bendansby.com/apps/keystruck/docs.html)）。
- AX 调用是**跨进程 IPC**，目标卡死会拖住遍历，需 `AXUIElementSetMessagingTimeout` 逐个设超时（二手来源，与其「全量扫描约 3 秒」描述一致：[HotkeyClash](https://hotkeyclash.com/blog/how-to-read-mac-menu-shortcuts-accessibility-api/)）。

### 1.3 权限与沙箱

- **需 Accessibility（TCC `kTCCServiceAccessibility`）**。本机实测：未授权时读 `kAXMenuBarAttribute` 返回 `-25211`（`kAXErrorAPIDisabled`，SDK `AXError.h`）。
- **沙箱下不可行**。Apple 把「Use of accessibility APIs in assistive apps」列入沙箱禁止清单（[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)）；DTS 工程师 Quinn：「The APIs gated by the `Accessibility` privilege are **not compatible** with the App Sandbox」，而 MAS 要求全部沙箱化（[Forums #820594](https://developer.apple.com/forums/thread/820594)）。
- 结论：**能力 B 无法以独立 App 上 MAS**，除非另做一套不带 AX 的降级版（只有系统级快捷键 + 自维护快捷键库）。

---

## 2. 检测「刚按了哪个快捷键」并识别动作名

### 2.1 四条路线对比

| 方案 | 拿到什么 | 权限 | 系统级键 | App 内键 |
|---|---|---|---|---|
| `AXObserver` + `AXMenuItemSelected` | **动作名**（"Save"）+ 键位 | Accessibility | ✗ | ✓（仅绑菜单项的） |
| `CGEventTap` listen-only | 键码 + 修饰 + flags | **Input Monitoring**（键盘类） | ✓ | ✓（无语义） |
| `NSEvent.addGlobalMonitorForEvents` | 同上 | **Accessibility** | ✓ | ✓（无语义） |
| `NSMenuItem` 被触发信号 | 只有**自己 App** | 无 | ✗ | ✗ |

1. **`AXMenuItemSelected` 是官方通知**：「Notification that a menu item has been seleted. Value is the selected menu item UIElement.」（原文拼写如此，[文档](https://developer.apple.com/documentation/applicationservices/kaxmenuitemselectednotification)）。KeyStruck 说明与之完全吻合：「observes accessibility notifications from the frontmost app… macOS fires that menu item and KeyStruck sees the action name」——**它不监听键盘，只监听菜单被触发**，故只需 Accessibility，且隐私政策写「does not capture keystrokes」（[docs](https://bendansby.com/apps/keystruck/docs.html) / [privacy](https://bendansby.com/apps/keystruck/privacy.html)）。
2. **`addGlobalMonitorForEvents` 的权限是 Accessibility 而非 Input Monitoring**：官方文档「Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access」，且「handler will not be called for events that are sent to your own application」（[API 文档](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))）。Quinn 亦确认这个反直觉点（[#820594](https://developer.apple.com/forums/thread/820594)）。
3. **CGEventTap 键盘事件受 assistive access 管控**。SDK `CGEvent.h`：「may only receive key up and down events if access for assistive devices is enabled… If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned.」（[Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services)）
4. 「菜单项高亮会发 AX 通知」在任何 Apple 文档中均无保证 → **未证实**，不作为方案。

### 2.2 本机实测：CGEventTap 权限矩阵

未授予任何 TCC 权限的进程中逐个建 tap（macOS 26.4 / arm64），**结果全为 NIL 的**：keyDown+listen-only（session）、keyDown+default（session）、scrollWheel+**default**（session 与 `cghidEventTap` 均 nil）、keyDown+listen-only（`cghidEventTap`）。**结果为 OK 的**：flagsChanged+listen-only、scrollWheel+listen-only。

→ **键盘事件要 Input Monitoring；「修改」滚动事件（能力 C）要 Accessibility**；非键盘类 listen-only tap 不受限。

### 2.3 KeyStruck 的实现线索（查证结果）

- **HUD 触发**：命中任何**绑定到菜单项**的快捷键即闪；连续触发**竖直堆叠**、各自计时淡出；可开关「⌘S Save」式前缀。
- **双击 ⌘ 长按出 cheat sheet**：双击 ⌘ 并**按住第二次约 0.5 秒**弹出，**松手即关**；按住期间加按 ⇧/⌥/⌃ 可按修饰键**过滤**；行可点击直接触发。明确「只在双击时打开、单次长按不打开」，避免与 App 自己的 ⌘-hold 冲突，⌘+拖拽也不误触。
- **快捷键浏览器**：`⌥⌘K`（可改）常驻窗口，召唤瞬间**快照**前台菜单（防后台重建导致列表跳动），支持搜索/回车触发/`⎋` 关闭。
- **排除列表**：按 **bundle identifier** 匹配 App；另有按快捷键排除，可选 `Everywhere` / `One app`。
- **形态**：自陈「pure SwiftUI + AppKit; tiny binary」→ 混合栈、无 Electron；自更新走 **Sparkle**；开机启动明确用 **SMAppService**（与 SDK 头文件一致）。
- **是否上架 MAS**：官网只提 Direct download + Setapp；隐私政策却专设「Sandboxing (Mac App Store version)」一节。本机 App Store 检索（关键词 + 开发者 Benjamin Dansby 的 App 列表）**均未找到** → **未证实**，且与「AX 不兼容沙箱」冲突。

### 2.4 推荐组合（v1）

- **主路径：只申请 Accessibility**，`AXObserver` 订阅 `AXMenuItemSelected` 出动作名；按下时回读该菜单项的 `AXMenuItemCmdChar`/`Modifiers` 补「⌘S」前缀 → **单一权限、不碰键盘流**，隐私话术最好讲。
- **可选增强：+ Input Monitoring**，listen-only tap 补盲区：系统级快捷键（对照 `com.apple.symbolichotkeys`）与未绑菜单的内部快捷键。
- 系统快捷键表来自**未文档化**的 `AppleSymbolicHotKeys`，条目为 `parameters = (字符码, 虚拟键码, NSEvent 修饰位)`；ID 无官方对照表，未改过的默认项常常不落盘。本机实测该域有 21 条，`60/64/65` 在列（[HotkeyClash](https://hotkeyclash.com/blog/how-to-read-mac-menu-shortcuts-accessibility-api/)）。

---

## 3. 鼠标 / 触控板滚动方向分离

### 3.1 为什么是绑定的

滚动方向是**一个全局偏好键**，不按设备存：`NSGlobalDomain` 的 `com.apple.swipescrolldirection`。本机实测：`defaults read -g` → `0`；`defaults -currentHost read -g` 下**不存在**该键；设备域（`com.apple.AppleMultitouchMouse` 等）只有 `MouseVerticalScroll`/`MouseMomentumScroll` 这类行为开关，**没有方向键**。系统只有「一个开关 → 全体输入源」这一条通路，要做分离只能**在事件流上按来源分别翻转**。（`com.apple.trackpad.momentumScroll` 存在，但也是全局触控板级。）

### 3.2 怎么区分「鼠标滚轮」与「触控板双指」

三个正交信号，Scroll Reverser 全用：

1. **`kCGScrollWheelEventIsContinuous`**（[CGEventField](https://developer.apple.com/documentation/coregraphics/cgeventfield/scrollwheeleventiscontinuous)）：连续 = 触控板/Magic Mouse，离散 = 滚轮。源码：`const BOOL continuous=!!CGEventGetIntegerValueField(eventRef, kCGScrollWheelEventIsContinuous);`（[MouseTap.m](https://github.com/pilotmoon/Scroll-Reverser/blob/master/Scroll%20Reverser/MouseTap.m)）
2. **HID 源**：`CGEventCopyIOHIDEvent(event)` → `IOHIDEventGetSenderID()`（HID event service 的 registry entry ID）→ 查 `Product/Transport/VendorID/ProductID/SerialNumber/HIDScrollAccelerationType`。触控板判据：`HIDScrollAccelerationType == HIDTrackpadScrollAcceleration` 或父节点是 Apple 多点触控驱动（[ScrollSource.m](https://github.com/pilotmoon/Scroll-Reverser/blob/master/Scroll%20Reverser/ScrollSource.m)）。
3. **`kCGEventSourceUnixProcessID`**：识别别家软件 post 的滚动（远程桌面、鼠标工具），这类无底层方向，只给 Reversed / Unchanged。
4. 另用 **`NSEvent.isDirectionInvertedFromDevice`** 问「系统是否反转了该设备」，把用户意图表达成 Natural / Classic / Unchanged（[文档](https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice)）。

### 3.3 各开源实现怎么做

| 项目 | Tap 位置/选项 | 判别来源 |
|---|---|---|
| **Scroll Reverser**（Apache-2.0, ObjC） | `kCGSessionEventTap` + `kCGTailAppendEventTap` + **`OptionDefault`**，mask 仅 scrollWheel | 三信号全用；每 source 独立存 Natural/Classic/Unchanged + 步长 |
| **LinearMouse**（MIT, Swift） | **`tap: .cghidEventTap, options: .defaultTap`** | `CGEventCopyIOHIDEvent` → sender ID → `device(for:)`；另有 5 秒健康检查 + `tapDisabledByTimeout` 自动重启用 |
| **Mac Mouse Fix**（源码公开，MMF License, ObjC） | 自建 event tap | 同类做法；细节未逐行核对 → **未证实** |
| **Mos**（CC BY-NC 4.0, Swift） | `ScrollCore.swift` 内建多个 tap（default + listenOnly） | 注释提到需 listenOnly 才能建第二份热键状态 |

**SPI 警告**：`CGEventCopyIOHIDEvent` 在公开 SDK 中**无头文件声明**，Scroll Reverser 自写 `CoreGraphicsSPI.h` 声明它，符号确实存在。这是 App Store 不友好的做法（Guideline 2.5.1 要求公开 API）。

### 3.4 最小实现 + 权限 + 副作用

**最小实现**：建 `tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << scrollWheel.rawValue)`；回调里 `type == .scrollWheel` 时读 `IsContinuous` —— `true`（触控板/Magic Mouse）**原样返回、一个字段都不改**；`false`（滚轮）**取负 `DeltaAxis1/2`，并同步改 `PointDeltaAxis1/2` 与 `FixedPtDeltaAxis1/2`**。不需要 IOHID、不需要设备表。

**权限**：`.defaultTap` 改滚动事件要 **Accessibility**（本机实测未授权时 `scrollWheel + .defaultTap` 直接 NIL，listen-only 能建但改不了事件）。

**性能与惯性**：回调跑在**事件分发路径上**（同步），必须 O(1)、不分配、不落盘、不加锁，否则被 `kCGEventTapDisabledByTimeout`（`0xFFFFFFFE`，SDK `CGEventTypes.h`）停掉，需自己 `tapEnable` 恢复（LinearMouse/Scroll Reverser 都实现了）。**不影响触控板惯性**：`isContinuous == true` 时零字段修改，`momentumPhase` 与 point delta 保持原样。**滚轮的坑**：只改 `DeltaAxis` 会让 macOS 反推 `PointDeltaAxis`（约 8×）从而**丢平滑滚动**，源码注释明写「we have to set the point values second, or we lose smooth scrolling」。

---

## 4. 工程与分发约束

### 4.1 本机环境事实（逐一验证）

- **可用**：macOS 26.4 (25E246) arm64；`swiftc`/`swift` Swift 6.3.3 (swiftlang-6.3.3.1.3)；SDK `MacOSX26.5.sdk`（`MacOSX.sdk` 软链，CLT 包 26.6.0）；`xcrun notarytool` / `xcrun stapler` / `codesign`（均在 CLT 内，公证**不需要 Xcode**）。
- **不可用**：`xcodebuild` —— `xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory … is a command line tools instance`。

### 4.2 没有 Xcode 能不能做 —— **能，本机已跑通**

跑通形态：`swift build -c release` → 手工建 `X.app/Contents/{MacOS,Resources}` → 手写 `Info.plist`（`CFBundleExecutable`/`CFBundleIdentifier`/`LSUIElement=true`/`LSMinimumSystemVersion`）→ `codesign -s -` → 启动正常，`NSStatusBar.statusItem` 可用，`Bundle.main.bundlePath` 正确。`LSUIElement=1` 官方语义：「does not appear in the Dock and does not have a menu bar」（[文档](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)）。

**四个坑（均实测）：**

1. **`Bundle.module` 路径陷阱（最坑）**。SwiftPM 生成的 `resource_bundle_accessor.swift` 只在 **`.app` 根目录**与**构建目录**两处找：`Bundle.main.bundleURL.appendingPathComponent("X_Y.bundle")` + 写死的 buildPath。实测放 `Contents/Resources/` → `Fatal error: could not load resource bundle`；挪到 `.app/` 根 → 正常。**对策**：资源进 `Contents/Resources` 就别用 `Bundle.module`，改自己算的 `Bundle(url:)`。
2. **ad-hoc 签名 = TCC 每次失效**。实测 `codesign -d -r- Probe.app` → `designated => cdhash H"702da4f2…"`；ad-hoc 的 DR 就是当次 cdhash，重编译即变 → 设置里开关还亮，AX 调用静默失败（`-25211`）、`CGEventTapCreate` 返 nil。开发期须 `tccutil reset Accessibility <bundle-id>` 再授权。换 Developer ID 后 DR 变「identifier + 证书」才稳定（[TCC cdhash 陷阱](https://nick-liu.com/posts/tcc-cdhash-trap/)）。
3. **entitlements**：Accessibility / Input Monitoring **不是 entitlement 而是 TCC**，写 entitlements 无用；公证要的是 `--options runtime`（Hardened Runtime）+ Developer ID + 安全时间戳。
4. **LaunchAtLogin**：`SMAppService.mainApp` **无需 Developer 证书**——实测 `register()` 成功（status `3→1`）、`unregister()` 成功（`→0`）。SDK：`A SMAppService corresponding to the main application as a LoginItem`（macOS 13+，[文档](https://developer.apple.com/documentation/servicemanagement/smappservice/register())）。

**HUD 窗口姿势**（SDK 可查）：`NSPanel` + `NSWindowStyleMaskNonactivatingPanel`（官方注释：`Specifies that a panel that does not activate the owning application. Only applicable for NSPanel`），闪 HUD 不抢焦点；`level` 至少 `NSStatusWindowLevel`，盖全屏用 `NSScreenSaverWindowLevel`；`collectionBehavior` 加 `.canJoinAllSpaces | .fullScreenAuxiliary | .stationary`（`Stationary: Unaffected by exposé`）（[level](https://developer.apple.com/documentation/appkit/nswindow/level) / [collectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior)）；`ignoresMouseEvents = true`。

**Sparkle**：SwiftPM 直接依赖即可，本机**在无 Xcode 环境下编译链接成功**，产物含 `Sparkle.framework`。但手工打包必须：放进 `Contents/Frameworks`、`-Wl,-rpath,@loader_path/../Frameworks`、**保留符号链接与可执行位**；Hardened Runtime 下 ad-hoc 签名可能加载不了 Sparkle（[Sparkle 文档](https://sparkle-project.org/documentation/)）。

### 4.3 三条分发路径

| | 官网直发 + Sparkle + 公证 | Mac App Store | 开源 GitHub Releases |
|---|---|---|---|
| 能做 A/B/C | **能** | **不能**（AX 不兼容沙箱） | 能 |
| 证书/账号 | Apple Developer Program **$99/年**；`Developer ID Application`（打 pkg 才需 Installer） | 同上 + App Store 记录 | 可 ad-hoc，但用户需手动放行 |
| 必备 | Hardened Runtime、安全时间戳、**不含 `get-task-allow`**、传 zip/dmg/pkg（**不能直接传 .app**） | 强制沙箱、必须用 Xcode 打包、更新必须走 MAS | 无 |
| 自动化 | `xcrun notarytool` + `xcrun stapler`（CLT 自带，本机可用） | `altool` 已废 | 无 |

出处：[Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)（证书类型、Hardened Runtime、时间戳、get-task-allow 禁令）；[Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/)（(i) 必须沙箱、(ii) 必须 Xcode 打包、(vii) 更新必须走 MAS）；[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)（「you can't upload the .app bundle directly」）。**公证流程本身不需要 Xcode**，只有「出归档」这步需自建脚本。

### 4.4 同类形态与体积（实测下载量）

| 产品 | 形态 | 分发包 |
|---|---|---|
| KeyStruck | 自陈「pure SwiftUI + AppKit」，无后台服务 | **6.4 MB**（dmg，`Content-Length: 6749585`） |
| LinearMouse | Swift + AppKit/SwiftUI | **5.0 MB**（dmg） |
| Scroll Reverser | Objective-C + AppKit | 1.68 MB（zip，官网自述） |
| Mac Mouse Fix | ObjC + AppKit，Xcode 工程 | 数十 MB 级（多语言 + Helper） |
| Karabiner-Elements | C++/Swift + **DriverKit 系统扩展** | 大（含驱动） |

→ **不带驱动与 Helper 的纯 Swift/SwiftUI 菜单栏工具，dmg 在 5–7 MB 量级**。不碰「虚拟键鼠」就无需 DriverKit 系统扩展，安装体验（不重启、不批驱动）好很多。

---

## 5. 权限与隐私话术

**首次启动要引导的开关**

- **Accessibility**（`Privacy & Security > Accessibility`）：读菜单栏（B）、收 `AXMenuItemSelected`（A）、改滚动事件（C）。检查/弹窗用 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`（本机实测未授权返回 `false`，[文档](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)）。
- **Input Monitoring**（`Privacy & Security > Input Monitoring`）：仅当自己监听键盘时才要（CGEventTap 键盘事件 / `CGRequestListenEventAccess` / `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`）。本机实测 `CGPreflightListenEventAccess()`、`CGPreflightPostEventAccess()`、`IOHIDCheckAccess(...)` 均返回未授权（[CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())）。
- **TCC 服务名↔面板对应（最易混）**：`PostEvent` 与 `Accessibility` **都映射到「辅助功能」**；`ListenEvent` 映射「输入监视」（DTS 原文，[#820594](https://developer.apple.com/forums/thread/820594)）。
- **话术建议**：只申请真正用的那个。若 v1 走 AX 通知路线就**只要 Accessibility**，可写「不读取你按了哪些键，只读取 App 刚刚触发了哪个菜单命令」——即 KeyStruck 的措辞（[privacy](https://bendansby.com/apps/keystruck/privacy.html)）。

**macOS 26 有什么新变化**

- **未证实**：没有任何 Apple 一手文档说明 macOS 26 对 Accessibility / Input Monitoring 引入「每月提醒」或「常驻授权」变更。[macOS Tahoe 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes) 无 TCC/AX 条目；[Apple Platform Security](https://support.apple.com/guide/security/welcome/web) 与 [Enterprise 更新说明](https://support.apple.com/en-us/124963) 中相关的只有「26.2 起 MDM 配置的隐私权限会显示在系统设置」这类企业管理条目。
- **确有其事的是「屏幕录制」**：自 Sequoia 起屏幕录制类 App 被**周期性**要求重新授权（每周→后放宽到每月，重启亦要求）。这是 **Screen Recording，不是 Accessibility**，只能作趋势旁证，**不能**说成 AX 也会每月弹（[记录](https://www.stclairsoft.com/blog/2024/08/07/sequoias-weekly-permission-prompts-for-screen-recording/)）。
- **真正让用户「反复授权」的是签名身份变化导致 TCC 失效**（见 4.2 坑 2）。Developer ID + 稳定 bundle id 即可避免。

---

## 6. 竞品与许可证格局

| 产品 | 类型 | 价格 | 开源/许可 | 核心能力 | 目标用户 |
|---|---|---|---|---|---|
| **KeyStruck** | 菜单栏 HUD + cheat sheet | **$5 一次性** | 闭源 | AX 菜单 → 动作名 HUD；双击⌘长按出表；快捷键浏览器 | 录屏/教学/学快捷键 |
| **CheatSheet** | cheat sheet | — | 闭源，**已停售**（官网 410、GitHub 404） | 长按⌘弹快捷键表 | 早期 Mac 用户 |
| **KeyCue** | cheat sheet | **$19.99 起** | 闭源 | 全 App 快捷键表 + 自定义/覆盖 + 系统热键可视化 | 效率老用户 |
| **Karabiner-Elements** | 键位重映射 | 免费（捐赠） | **Unlicense（公有领域）** | 深度改键、复杂规则、虚拟键鼠（DriverKit 扩展） | 高级用户 |
| **LinearMouse** | 鼠标/触控板 | 免费 | **MIT** | 按设备/按 App 的滚动与指针、按键重映射 | 外接鼠标用户 |
| **Mac Mouse Fix** | 鼠标增强 | **$2.99**（30 天试用） | **源码公开但非 OSI**：自定义 MMF License（禁止收费分发，除非有实质改进） | 滚轮平滑/加速、按键手势 | 外接鼠标用户 |
| **Scroll Reverser** | 滚动方向 | 免费 | **Apache-2.0** | **按设备/按 App 分别设滚动方向**（§3 原型） | 鼠标+触控板混用 |
| **Mos** | 滚轮平滑 + 方向 | 免费 | **CC BY-NC 4.0（禁商用！）** | 滚轮平滑曲线、单独设鼠标方向 | 外接鼠标用户 |
| **BetterTouchTool** | 全家桶自动化 | **$15**（2 年更新）/ **$25** 终身 | 闭源 | 手势/按键/菜单栏/Stream Deck/动作链 | 重度自定义玩家 |
| **Raycast** | 启动器平台 | 免费 / Pro **$10/月**（年付 $96） | 闭源 | 启动器 + 扩展 + AI + 窗口管理 | 通用效率用户 |
| **Kinto** | **反向**：Mac 快捷键搬到 Win/Linux | 免费 | **GPL-2.0** | Windows/Linux 上模拟 ⌘ 语义（AHK / xkeysnail） | Win/Linux 上的 Mac 用户 |

**读表判断：**
- **「Windows→Mac」方向没有对标的成熟商业产品**：Kinto 是反方向；macOS 侧只有 Karabiner 的 community 规则集做 Ctrl↔Cmd 互换，无独立 App 品牌 → **未证实存在成规模直接竞品**，是空位。
- **许可证两处雷**：Mos 是 **CC BY-NC 4.0（禁商用）**，不能抄；Mac Mouse Fix 是**自定义非 OSI 许可**，读可以、抄进商业产品不行。可安全借鉴的是 **Scroll Reverser（Apache-2.0，保留 NOTICE）**与 **LinearMouse（MIT）**。
- **价格锚点**：单点工具 $2.99–$5，cheat sheet $19.99，全家桶 $15–$25。多能力合一的迁移助手，$9–$19 一次性定价有市场一致性。

---

## 7. 对 v1 的可行性结论

### 7.1 低风险，可直接做

| 能力 | 判断 | 依据 |
|---|---|---|
| **B：列前台 App 全部快捷键** | ✅ 最稳。纯只读 AX 遍历，无注入、无性能风险，只需 Accessibility | §1.1/1.3 |
| **A 的展示层（HUD）** | ✅ 无风险。`NSPanel` + nonactivating + status/screenSaver 层级，不抢焦点、不进 Dock | §4.2 |
| **A 的动作识别（AX 通知路线）** | ✅ 低风险。`AXMenuItemSelected` 是官方通知，且能复用 B 的菜单树拿键位 | §2.1 |
| **工程基座** | ✅ 本机已验证：SwiftPM + 手搓 .app + LSUIElement + SMAppService，无需 Xcode.app | §4.1/4.2 |

### 7.2 有额外成本 / 需更多权限

| 能力 | 风险点 |
|---|---|
| **A 覆盖非菜单 + 系统级快捷键** | 必须再加 **Input Monitoring**，隐私观感陡降；系统快捷键表来自未文档化的 `AppleSymbolicHotKeys`，需自维护 ID→名称映射，默认项常常不在盘上 → 永远做不全 |
| **C：滚动方向分离** | 需 **Accessibility + `.defaultTap`**（要改事件）；回调在事件热路径，须有超时重启用逻辑；`CGEventCopyIOHIDEvent` 是 **SPI**——但只做「滚轮 vs 触控板」二分可完全不用它（只读 `IsContinuous`），**v1 建议就这么做**，SPI 留到 v2 需「按具体鼠标分别设」时再上 |
| **开发期体验** | ad-hoc 签名 → 每次重编译 TCC 失效，须 `tccutil reset`；建议尽早办 Developer ID |

### 7.3 触碰红线 / 不可行

- **整个产品上 MAS**：❌ 不可行（AX 与沙箱不兼容，Apple 文档 + DTS 双重确认）。坚持 MAS 只能砍掉 A/B 的 AX 部分，退化成「静态快捷键百科」，价值大打折扣。
- **沙箱内用 CGEvent 改滚动事件**：❌（`.defaultTap` 需 Accessibility，同红线）。
- **枚举别的 App 用 `RegisterEventHotKey` 注册的全局热键**：❌ 无公开 API。
- **发现任意 App 内部快捷键（未绑菜单项）**：❌ 系统层面不可见。
- **依赖 `AXMenuItemMarked` 之类非官方信号做触发**：❌ 未证实，不要用。

### 7.4 建议的技术形态

1. **一句话**：**纯 Swift（SwiftUI + AppKit 混合）菜单栏 App，`LSUIElement=true`，官网直发 + Sparkle + notarytool 公证，不上 MAS**，目标 dmg ≤ 8 MB。
2. **权限分档**：**默认档只申请 Accessibility**（B 全量 + A 的菜单快捷键部分 + C，已覆盖 Windows 用户最痛的三件事）；**Input Monitoring 做成可选开关**，开启后才扩展 A 到系统级与非菜单快捷键。**不要让它成为首次启动的必选项。**
3. **A 的优先级**：先 `AXObserver(AXMenuItemSelected)`——唯一「零键盘监听拿到动作名」的路径；CGEventTap 只作可选补充。
4. **C 的优先级**：**先做「滚轮 vs 触控板」二分**（`kCGScrollWheelEventIsContinuous`，零 SPI），「按具体鼠标分别设」放 v2。
5. **Developer ID（$99/年）应在 v0 之前办下来**——不是为了公证，而是让 TCC 授权在迭代间稳定，否则每改一次代码都要重新授权。
6. **不做的事**：不做虚拟键鼠（避开 DriverKit 扩展，省掉重启/批驱动的安装流程）；不做 Electron（同体量产品都是原生，体积差 10 倍以上）；不抄 Mos（NC）与 Mac Mouse Fix（自定义协议）的代码。

---

### 附：复现命令

`sw_vers; uname -m; xcodebuild -version; /usr/bin/swiftc --version`（环境）· `xcrun --show-sdk-path`、`xcrun notarytool --help`（CLT 自带公证工具）· `defaults read -g com.apple.swipescrolldirection`（方向是全局的）· `defaults -currentHost read -g | grep -i scroll`（无设备级方向键）· `codesign -d -r- YourApp.app`（ad-hoc 的 DR 就是 cdhash）

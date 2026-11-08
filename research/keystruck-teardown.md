# KeyStruck 拆解（事实版）

> 来源：官方产品页 <https://bendansby.com/apps/keystruck.html> 与官方文档 <https://bendansby.com/apps/keystruck/docs.html>（2026-11-08 抓取）。
> 本文只记录**对方明确写出来的事实**，不脑补实现。凡是推断都标了「推断」。

## 1. 它是什么

一个菜单栏常驻的小工具，做两件事：

1. **HUD 吐司**：你按了任何绑定到菜单项的快捷键，它浮出一个毛玻璃胶囊，写这个动作的名字（Save / Reload Page / Copy 2 Items）。
2. **速查面板**：双击 ⌘ 并按住第二下约 0.5 秒，列出前台 App 绑定的所有快捷键，按菜单分组；按住 ⇧/⌥/⌃ 可过滤组合。

定价：一次性买断（另有 Setapp 版本）。要求 macOS 13+，Apple Silicon 与 Intel 均支持，官网版走 Sparkle 自动更新。技术栈自称「纯 SwiftUI + AppKit，体积极小，瞬间启动，无后台服务」。

## 2. 工作原理（官方原话，这是最关键的一段）

> "KeyStruck observes accessibility notifications from the frontmost app. When you press a key combination that the app has bound to a menu item, macOS fires that menu item and KeyStruck sees the action name."
>
> "KeyStruck does not log keystrokes. It reads the name of the menu item the system just fired — 'Save', 'New Tab' — not the keys themselves, and nothing leaves your Mac."

也就是说：

- 它**不是**键盘记录器，而是**观察 AX 通知**（菜单项的触发/状态变化）。
- 数据源是**菜单栏**，不是内置快捷键字典。
- 需要 **Accessibility（辅助功能）TCC 授权**，首次启动引导你去系统设置里开。
- 未授权时：App 照常运行，但 HUD 不出现；偏好设置里有 Permissions 区可以重新检查。

**推断**：这份「不记录按键、只读动作名」的定位同时是隐私话术和过审话术——它让「这软件要看我的键盘」变成一个可以接受的请求。

## 3. 官方承认的能力边界（"What KeyStruck can't see"）

这一段最有价值，它等于把这类产品的天花板写出来了：

| 看不见的类型 | 原因 |
|---|---|
| Carbon hotkeys（老式全局热键） | 不触发菜单项通知 |
| 不绑定菜单项的快捷键 | App 内部自己处理按键，没有菜单激活可观察 |
| 系统处理的快捷键（⇧⌘5、⌘Space 等） | macOS 在 App 之前就吃掉 |

推论：**任何"读菜单栏"路线都只能覆盖有菜单项的 App 内快捷键**；Electron/Chromium 系如果 AX 暴露菜单则可用（待验证，见 tech-feasibility），游戏和自绘 UI 基本不可用。

## 4. 功能清单（可抄的部分）

| 模块 | 细节 |
|---|---|
| HUD 位置 | Center / top center / bottom center / top-bottom left / top-bottom right，共 7 个 |
| HUD 时长 / 字号 | 可调；连续触发会**纵向堆叠**，各自独立计时淡出 |
| HUD 外观 | Auto/Light/Dark（Auto 取系统模式的反面，保证对比度）；毛玻璃可关成实心 + 不透明度可调 |
| 动画 | Spring 弹入，自动尊重「减弱动态效果」系统设置 |
| 声音 | Pop / Tink / Glass / Ping / Morse / Purr 六种，默认关 |
| 前缀 | 可选把触发键显示在动作名前：「⌘S Save」或只写「Save」 |
| 速查面板 | 双击 ⌘ + 按住 0.5 秒触发；**只在双击时开，单击长按不开**，避免与 App 自己的 ⌘-hold 行为冲突；拖拽窗口时不触发 |
| 面板过滤 | 持有 ⌘ 时再按 ⇧/⌥/⌃ 收窄列表，松开恢复；表头显示匹配条数 |
| 面板点击即执行 | 点任意行直接触发该菜单动作，**不抢前台焦点**；当前不可执行的动作（剪贴板空时的 Paste）变灰且点不动 |
| 快捷键浏览器 | 常驻窗口 + 实时搜索，⌥⌘K 或菜单栏唤出；**唤出瞬间快照菜单**，避免搜索时列表跳动；支持纯字符键（I/O/K/Space/方向键）——这是面板做不到的，因为面板只列"当前按住的修饰键"匹配项 |
| 浏览器键盘操作 | 输入过滤；↓ 从搜索框进列表；↑ 回到搜索框；⏎ 执行并关闭；⎋ 关闭 |
| 全局热键 | 默认 ⌥⌘K，可重录，可清空 |
| 排除 | 按 App（按 bundle id 匹配，改名/移动不失效）+ 按快捷键（四修饰键芯片 + 单字符键，可无修饰键，作用域 Everywhere / 单 App） |
| 生命周期 | 菜单栏图标可隐藏、开机启动用 `SMAppService`、Reset to defaults（不含 AX 授权） |
| 本地化 | 11 种语言，含简体中文 |

## 5. 对 better-macOS 的启示

**要抄的**（这些是打磨出来的交互决定，重造一遍毫无意义）：

- 「观察菜单动作」而不是「记录按键」——技术上更省、隐私上更干净、话术上更安全。
- 面板的**触发方式**：双击 ⌘ + 按住。它不占全局快捷键、不会在正常打字时误触、松开即消失。
- 面板里**点击即执行**，且不抢焦点。这让面板从「说明书」变成「工具」。
- 唤出时**快照**，避免后台重建菜单导致列表跳动。
- 不可执行项**变灰**而不是隐藏。
- 排除规则用 bundle id 匹配。

**不要抄的 / 要改的**：

- 它的定位是「给已经适应 Mac 的人看清自己在按什么」——**动作名是 Mac 词汇**（Save、New Tab）。Windows 迁移者要的是**对照**：这个动作在 Windows 里是哪几个键、我原来的肌肉记忆对应到哪里。
- 它没有任何"系统疼痛修正"能力（滚动、键位互换、窗口）。这部分是我们要长的第二层（L2）。
- 它是闭源商业软件；我们 MIT + GitHub Releases，天然可以做得更"可改造"。

## 6. 开放问题（待研究确认）

1. 跨 App 读菜单是否真如文档所说只需 Accessibility 一项授权？是否需要 Input Monitoring？
2. AX 观察菜单"被触发"的具体通知是什么（`kAXMenuItemSelected`？state changed？）——本机 spike 已能读自己菜单，跨 App 待授权验证。
3. Chromium 系（Chrome / Electron）的 AX 菜单暴露完整度。
4. 双击 ⌘ 的检测是否需要 CGEventTap（即是否需要 Input Monitoring），还是 AX 通知足够。

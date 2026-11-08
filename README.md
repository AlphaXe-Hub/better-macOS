# better-macOS

让 Windows 用户丝滑迁移到 macOS 的菜单栏工具。

> 一个 App · 两层能力
> **L1 学习层**：看清你按了什么（吐司提示 + 快捷键面板）
> **L2 修正层**：把系统做不到的事补上（鼠标/触控板滚动方向分离）

## 现在能做什么

**L1 — 吐司提示**：按下任何绑定到菜单的快捷键，屏幕中央浮出一张毛玻璃卡片，
告诉你这个动作的名字（比如按 ⌘S 浮出「Save」）。连续触发会纵向堆叠。
它**不记录你按了哪些键**，只读「App 刚刚触发了哪个菜单命令」。

**L1 — 快捷键面板**：⌥⌘K 唤出，列出当前前台 App 的全部快捷键，
按菜单分组、支持搜索、双击执行。

**L2 — 滚动方向分离**：系统只有一个「自然滚动」开关，鼠标滚轮和触控板被绑在一起。
打开后，触控板保持自然滚动，鼠标滚轮恢复 Windows 方向——**两者独立**。

## 我们看不到什么

与其假装什么都能看见，不如把边界说清楚：

| 看不到 | 为什么 |
|---|---|
| 系统级快捷键（⌘Space、⇧⌘5、⌘Tab） | macOS 在任何 App 之前就处理掉了 |
| 没绑定菜单项的快捷键 | App 内部自己处理按键，没有菜单激活可观察 |
| Carbon 注册的老式全局热键 | 不触发菜单通知 |

## 安装（开发者）

需要 macOS 14+、Command Line Tools（**不需要 Xcode.app**，不需要开发者证书）。

```bash
./app/build.sh               # 构建
./app/build.sh release run   # 构建并启动
```

首次启动会引导你授予**辅助功能**权限。没有它，菜单栏图标还在但什么都不会发生
（这是 macOS 的限制，不是 bug）。

## 开发时的坑

| 坑 | 说明 |
|---|---|
| **每次重新编译，权限都失效** | ad-hoc 签名的 designated requirement 就是那次编译的 cdhash，重建必变。用 `tccutil reset Accessibility dev.better-mac.app` 后重新授权 |
| **swiftc 必须带 `-target`** | 否则撞上 CLT 里 SDK(6.3.2) 与编译器(6.3.3) 的 arm64e slice 不匹配，报错信息会误导成「SDK 不支持」 |
| **未授权时 API 返回值会骗人** | `CGEvent.tapCreate` / `addGlobalMonitor` 可能返回非 nil 但零投递。判断权限只能看 `AXIsProcessTrusted()` |
| **`AXEnabled` 不可靠** | App 里禁用的菜单项，AX 仍可能报 enabled=1。跨 App 场景**做不到**「禁用项变灰」 |

## 结构

```
app/
  Sources/
    MenuInventory.swift    AX 菜单树 → 快捷键模型（深模块：只回答「这个 App 有哪些快捷键」）
    TriggerObserver.swift  AXMenuItemSelected 观察（深模块：只回答「刚触发了什么」）
    HUDWindow.swift        吐司（深模块：只有 show()）
    ShortcutBrowser.swift  快捷键面板
    Corrections.swift      L2 修正层：Correction 协议 + 滚动分离实现
    Preferences.swift      设置窗口
    AppDelegate.swift      编排（只接线，不含业务逻辑）
  build.sh                 CLT-only 构建脚本
research/                  调研事实（每条带出处）
docs/decisions.md          决策记录
```

## 设计原则

**深模块**：小的接口 + 厚的实现。`HUDController` 的接口就是 `show(content)`，
调用方不需要知道窗口层级、毛玻璃材质、堆叠策略中的任何一件事。

**一个修正项只暴露四件事**：我是谁、我开着吗、打开、还原。
加一个新的痛点不需要改 UI 一行代码。

**必须能撤回**：L2 的每个开关都必须能彻底还原到系统默认，否则用户不敢打开。

## 许可

MIT

# better-macOS

<img src="docs/assets/icon.png" width="96" align="right" alt="better-macOS 图标">

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

**L1 — 点击教练**：你用鼠标点菜单里的「文件 → 存储」时，浮出一句「存储 ⌘S」。
目标是把「点点点」换成快捷键——刚点完的那一刻，是你最需要知道答案的时候。
同一个动作最多提示 3 次，之后安静。只对**带快捷键的菜单项**生效
（工具栏按钮没有无障碍标签，教不了，宁可沉默也不猜）。

**L2 — 滚动方向分离**：系统只有一个「自然滚动」开关，鼠标滚轮和触控板被绑在一起。
打开后，触控板保持自然滚动，鼠标滚轮恢复 Windows 方向——**两者独立**。

## 我们看不到什么

与其假装什么都能看见，不如把边界说清楚：

| 看不到 | 为什么 |
|---|---|
| 系统级快捷键（⌘Space、⇧⌘5、⌘Tab） | macOS 在任何 App 之前就处理掉了 |
| 没绑定菜单项的快捷键 | App 内部自己处理按键，没有菜单激活可观察 |
| Carbon 注册的老式全局热键 | 不触发菜单通知 |
| **冷启动中的 App（前 0.3~5 秒）** | 进程已经在了，但菜单栏还没建好。这期间 AX 返回 `-25204` 但我们读不到东西。会自动重试约 2 秒，更长的窗口期要等你切走再切回来 |
| **真的卡住的 App** | 等满 2 秒超时后报 `cannotComplete`，不会重试（每次重试都要再等 2 秒）。详见 [docs/ax-electron.md](docs/ax-electron.md) |

## 安装（开发者）

需要 macOS 14+、Command Line Tools（**不需要 Xcode.app**，不需要开发者证书）。

```bash
./app/build.sh               # 构建
./app/build.sh release run   # 构建并启动
```

首次启动会引导你授予**辅助功能**权限。没有它，菜单栏图标还在但什么都不会发生
（这是 macOS 的限制，不是 bug）。

### 给开发者的第一步：建一个开发证书

```bash
./app/setup-devcert.sh    # 只需跑一次
```

**别跳过这步。** 默认用 ad-hoc 签名，它的 designated requirement 是当次编译的
cdhash——每重编译一次，系统里的授权就作废，表现是「设置里开关还亮着，但功能全挂」。
自签名证书让签名身份固定，授权只需一次。这不需要 $99 的开发者账号。

## 开发时的坑

| 坑 | 说明 |
|---|---|
| **每次重新编译，权限都失效** | ad-hoc 签名的 designated requirement 就是那次编译的 cdhash，重建必变。用 `tccutil reset Accessibility dev.better-mac.app` 后重新授权 |
| **swiftc 必须带 `-target`** | 否则撞上 CLT 里 SDK(6.3.2) 与编译器(6.3.3) 的 arm64e slice 不匹配，报错信息会误导成「SDK 不支持」 |
| **未授权时 API 返回值会骗人** | `CGEvent.tapCreate` / `addGlobalMonitor` 可能返回非 nil 但零投递。判断权限只能看 `AXIsProcessTrusted()` |
| **`AXEnabled` 不可靠** | App 里禁用的菜单项，AX 仍可能报 enabled=1。跨 App 场景**做不到**「禁用项变灰」 |
| **激活通知收不到** | `NSWorkspace.didActivateApplicationNotification` 只在**自己是活跃 App** 时投递。LSUIElement App 永远不是，实测切换 0 条通知 → 必须轮询 `frontmostApplication` |
| **`-25212`/`-25204` 不是错误** | 后台进程、菜单栏小组件本来就没有菜单栏。把它们当错误报给用户，就会出现「读不到当前 App 清单」的假故障 |
| **`hidesOnDeactivate` 默认 true** | NSPanel 默认值。accessory App 永远不 active → 面板一创建就自己藏起来，表现为「点了没反应而不报错」 |
| **`AXIsProcessTrusted()` 会撒谎** | 从终端直接跑二进制会**继承终端的授权**返回 true；只有经 `open`/Finder/Dock 启动才是真实状态。调试时用终端跑会得出错误结论 |
| **ad-hoc 签名 = 授权反复失效** | designated requirement 就是当次 cdhash。跑 `./app/setup-devcert.sh` 建固定签名身份可根治 |

## 结构

```
app/
  Sources/
    MenuInventory.swift    AX 菜单树 → 快捷键模型（深模块：只回答「这个 App 有哪些快捷键」）
    TriggerObserver.swift  AXMenuItemSelected 观察（深模块：只回答「刚触发了什么」）
    HUDWindow.swift        吐司（深模块：只有 show()）
    ShortcutBrowser.swift  快捷键面板
    ClickCoach.swift       L1 点击教练：CGEventTap + AX 命中菜单项
    Corrections.swift      L2 修正层：Correction 协议 + 滚动分离实现
    Preferences.swift      设置窗口
    AppDelegate.swift      编排（只接线，不含业务逻辑）
  build.sh                 CLT-only 构建脚本
  tools/
    make-icons.swift       源图 → AppIcon.icns / 菜单栏模板图（去噪、裁切、排布）
    gen-icons.sh           上面那个的调用入口
  Resources/
    source-app.png         主体图标源图（蓝）
    source-status.png      菜单栏图标源图（白）
    AppIcon.icns           生成物，已入库
    MenuBarIcon*.png       生成物，已入库
research/                  调研事实（每条带出处）
docs/decisions.md          决策记录
docs/click-coach.md        点击教练：为什么只认菜单项、为什么必须用 CGEventTap
```

图标不是手工切图，而是由 `app/tools/gen-icons.sh` 从两张 2048px 源图生成。
因为源图是 AI 出图，背景有 alpha 最高到 32 的压缩噪点，直接缩放会让菜单栏
模板图带一圈脏边；而且字形只占画布 58%×83%，不按包围盒重排会又偏又小。
脚本做的事：连通域去噪 → 按字形包围盒裁切 → 排进 macOS 图标网格（824/1024
超椭圆底板）→ 导出 10 档 iconset → `iconutil` 打包。

菜单栏图是**模板图**（`isTemplate = true`）：只存 alpha，颜色由系统按菜单栏
明暗自动染成黑或白。所以源图虽然是纯白，深色菜单栏下也不会变成一块白方块。

## 设计原则

**深模块**：小的接口 + 厚的实现。`HUDController` 的接口就是 `show(content)`，
调用方不需要知道窗口层级、毛玻璃材质、堆叠策略中的任何一件事。

**一个修正项只暴露四件事**：我是谁、我开着吗、打开、还原。
加一个新的痛点不需要改 UI 一行代码。

**必须能撤回**：L2 的每个开关都必须能彻底还原到系统默认，否则用户不敢打开。

## 推送

标准流程：

```bash
git push origin main
```

如果在某些网络环境下 `github.com:443` 不通而 `api.github.com` 可用，
可以走 GitHub 的 Git Data API 上传（改 tree 内容而非 packfile）。
这类脚本属于本机环境的 workaround，**不在本仓库内**——它解决的是你的网络，
不是项目需要的东西。

**注意**：这样推上去的 commit SHA 会和本地不同（作者/时间戳差异），
但 tree 内容一致；网络恢复后执行 `git fetch origin && git reset --hard origin/main`
对齐即可。

## 自动化

| Workflow | 触发 | 做什么 |
|---|---|---|
| **Build Check** | push / PR | macOS runner 上构建 + 285 项自测 + 产物结构校验（含 `LSUIElement=true`、图标资源齐备） |
| **Issue Triage** | issue 新建/编辑 | 自动分类打标签、检查缺陷报告信息完整度、缺什么就回帖说要什么 |

Issue Triage **刻意不做自动改代码**：issue 正文是不可信输入，
让有仓库写权限的 workflow 去执行其中的指令是危险面。

## 许可

MIT

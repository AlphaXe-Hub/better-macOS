# better-macOS · 1.0

一个 macOS 菜单栏 App，让 Windows 用户丝滑迁移到 macOS。

**代码：**[app/](../app/) · **决策记录：**[decisions.md](decisions.md) · **调研：**[research/](../research/)

## 跑起来

```bash
./app/build.sh release run    # 构建并启动
./app/test.sh                 # 285 项自测
./app/e2e.sh                  # 34 项端到端断言（吐司真的在屏幕上）
```

不需要 Xcode，不需要开发者证书。首次启动会引导授予**辅助功能**权限。

## 1.0 交付了什么

| 层 | 内容 | 状态 |
|---|---|---|
| **L1 学习** | 按键吐司（按下菜单快捷键，浮出动作名） | ✅ 34 项端到端验证 |
| **L1 学习** | 快捷键面板（⌥⌘K，分组/搜索/双击执行） | ✅ 可跑 |
| **L1 学习** | **点击教练**：用鼠标点菜单项时，提示它的快捷键 | ✅ 真机验证 + 衰减 |
| **L1 学习** | **Windows 对照**：吐司第二行显示 `Windows: Ctrl+S` | ✅ 24 条高频对照 |
| **L1 学习** | **系统快捷键解释**：`fn⌃←` 等查不到时说明为什么 | ✅ 31 条有出处 |
| **L2 修正** | `Correction` 协议 + 滚动方向分离（鼠标/触控板独立） | ✅ 两个实现 |
| **L2 修正** | 回车键不再重命名（F8 迁移痛点） | ✅ 第二个修正项 |

### 1.0 相对设计阶段的三个变化

**① Windows 对照从「v2 钩子」提前到 1.0 落地。**
设计阶段它只是数据结构里一个恒为 nil 的字段。做完调研后判断，这项恰恰是
Windows→Mac 方向上**没有任何商业产品覆盖**的空白（见 [research/pain-points.md](../research/pain-points.md) §8.1），
比「再多一个快捷键查看器」有价值。所以先填了 24 条最高频对照——只填高频，
不穷举：错一条比缺十条更伤。

**② 点击教练成了第三条学习通道。**
按键吐司有个前提：用户已经在按快捷键了。而迁移期用户还在「点点点」，
这条通道对他完全沉默。点击教练盯的是**他用鼠标点菜单的那一刻**——
那时意图最明确，答案就在手指旁边。详见 [click-coach.md](click-coach.md)。

**③ fn 从「被忽略」变成「独立一位」。**
`fn⌃←`（平铺左半屏）和 `⌃←`（左移一格）曾被识别成同一个组合。**误报比漏报更糟**：
显示了错误的名字，用户就再也不信任何提示了。

## 关键实现决定

**放弃 `AXMenuItemSelected`，改为「监听按键 + 反查菜单」**

这是整个项目最重要的技术转向，有完整实测证据（[research/ax-notification-dead-end.md](../research/ax-notification-dead-end.md)）：

- 在 `AXMenuItem` 上注册该通知 → 一律返回 `-25207`（不支持），「回调里拿到具体菜单项」这条路走不通
- 在 `menuBar`/`AXApplication` 上注册 → 返回 0，但合成 ⌘S 与 `AXPress` 两种真实触发下**均 0 条通知**，而动作确实执行了
- 两次实验都是自读自己进程，不需要授权，所以不存在「没授权所以收不到」的解释

改成监听按键后：用的是**同一个 Accessibility 权限**，且**能解释「按了但没绑定」**
——观察派在用户按空键时什么都看不到，而这对迁移者恰恰是最需要解释的时刻。

**只申请一个权限。** 不碰 Input Monitoring。

**点击教练必须用 `CGEventTap`，不能用 `NSEvent` 全局监听。**
菜单展开时 AppKit 进入自己的模态跟踪循环，`NSEvent.addGlobalMonitorForEvents`
**一条都收不到**——而「点菜单」正是这个功能唯一的场景。测出来之前没人会知道。

**宁可沉默，不可教错。** 工具栏按钮的 `AXTitle`/`AXDesc`/`AXHelp` 实测全空
（自绘图标，没有无障碍标签），所以点击教练**只认菜单项**。猜错一次，
用户就再也不信这个工具的任何提示。

## 边界（说清楚，不假装）

**看不到的**：系统级快捷键（⌘Space/⇧⌘5/⌘Tab）、未绑定菜单的快捷键、Carbon 老式全局热键。
这些不是没做完，是系统层面不可见。App 的做法是**明确告诉用户为什么看不见**，
而不是让他自己发现「有时候不灵」。详见 README 的边界表。

**已知未验证的**（对应仍开着的 issue）：
- 真实物理滚轮鼠标的滚动方向分离（#3）——需要一台真实滚轮设备
- 微信/飞书等 Electron 应用的菜单读取（#6）
- 拖拽式权限引导在 macOS 14/15/26 各版本的表现（#8）
- 未公证 DMG 在别人机器上的 Gatekeeper 表现（#7）

## 开发时的坑

| 坑 | 说明 |
|---|---|
| 每次重编译权限都失效 | ad-hoc 签名的 DR 就是当次 cdhash。跑 `./app/setup-devcert.sh` 建固定签名身份可根治 |
| `swiftc` 必须带 `-target` | 否则撞 CLT 里 SDK 与编译器的 arm64e slice 不匹配，报错会误导成「SDK 不支持」 |
| 未授权时 API 返回值会骗人 | `tapCreate`/`addGlobalMonitor` 可能返回非 nil 但零投递。判断权限只能看 `AXIsProcessTrusted()` |
| `AXEnabled` 不可靠 | App 里禁用的菜单项，AX 仍可能报 `enabled=1`。跨 App 做不到「禁用项变灰」 |
| `hidesOnDeactivate` 默认 true | NSPanel 默认值。accessory App 永远不 active → 面板一创建就自己藏起来 |
| `AXIsProcessTrusted()` 会撒谎 | 从终端直接跑二进制会继承终端的授权。只有经 `open`/Finder 启动才是真实状态 |

完整清单见 README。

## 调研

| 文件 | 内容 |
|---|---|
| [keystruck-teardown.md](../research/keystruck-teardown.md) | KeyStruck 能做什么、官方承认的边界 |
| [pain-points.md](../research/pain-points.md) | 36 条迁移痛点，🟢19 / 🟡13 / 🔴4，带证据分级 |
| [tech-feasibility.md](../research/tech-feasibility.md) | 技术全景、竞品格局、分发路线、许可证雷区 |
| [build-spike.md](../research/build-spike.md) | CLT-only 构建验证，18/18 项 |
| [ax-verified-facts.md](../research/ax-verified-facts.md) | 亲手验证的 AX/CGEventTap 事实清单 |
| [ax-notification-dead-end.md](../research/ax-notification-dead-end.md) | ⚠️ 推翻主路径的实测记录 |

## 下一步（1.x 之后）

1. **真实设备验证** —— 滚轮鼠标（#3）、多个 Electron 应用（#6）。这是当前最大的未知
2. **Developer ID（$99/年）** —— 用户下载后不用右键绕过 Gatekeeper 的前提（#7）
3. **Sparkle 自动更新** —— EdDSA 签名，与 Apple 证书无关，可独立工作

## 许可

MIT

# better-macOS · v1

一个 macOS 菜单栏 App，让 Windows 用户丝滑迁移到 macOS。

**代码：**[app/](app/) · **决策记录：**[docs/decisions.md](docs/decisions.md) · **调研：**[research/](research/)

## 跑起来

```bash
./app/build.sh release run    # 构建并启动
./app/test.sh                 # 31 项自测
```

不需要 Xcode，不需要开发者证书。首次启动会引导授予**辅助功能**权限。

## 三层交付

| 层 | 内容 | 状态 |
|---|---|---|
| **L1 学习** | 吐司 HUD（按下带修饰键的组合，浮出动作名）+ 快捷键面板（⌥⌘K，分组/搜索/双击） | ✅ 可跑 |
| **L2 修正** | `Correction` 协议 + 滚动方向分离（鼠标/触控板独立） | ✅ 协议与首个实现完成 |
| **v2 钩子** | 数据结构里预留 `windowsEquivalent` 字段，v1 全为 nil | ✅ 地基已付 |

## 关键实现决定

**放弃 `AXMenuItemSelected`，改为「监听按键 + 反查菜单」**

这是 v1 最重要的一个技术转向，有完整实测证据（见 [research/ax-notification-dead-end.md](research/ax-notification-dead-end.md)）：

- 在 `AXMenuItem` 上注册该通知 → 一律返回 `-25207`（不支持），「回调里拿到具体菜单项」这条路根本走不通
- 在 `menuBar`/`AXApplication` 上注册 → 返回 0，但合成 ⌘S 与 `AXPress` 两种真实触发下**均 0 条通知**，而动作确实执行了
- 两次实验都是自读自己进程，不需要授权，所以不存在「没授权所以收不到」的解释

改成监听按键后：用的是**同一个 Accessibility 权限**（`addGlobalMonitorForEvents` 的键盘事件要的是辅助功能，不是输入监控），且**能解释「按了但没绑定」**——观察派在用户按空键时什么都看不到，而这对迁移者恰恰是最需要解释的时刻。

**只申请一个权限。** 不碰 Input Monitoring。

**吐司的三条过滤规则**（写在 `AppDelegate.handleKey` 里，有测试覆盖）：
1. 不按修饰键 → 是打字，绝不弹
2. 单独按修饰键 → 不是动作，不弹
3. 有修饰键但未绑定 → 默认不弹，可在设置里打开（"解释为什么没反应"）

## 目前的边界

**看不到的**：系统级快捷键（⌘Space/⇧⌘5/⌘Tab）、未绑定菜单的快捷键、Carbon 老式全局热键。
这些不是没做完，是系统层面不可见——写进 README 比让用户自己发现「有时候不灵」好。

**还没验证的**（需要你手动授权一次才能测）：
- 授权后键盘监听的**真实投递率**
- 跨 App 读取菜单的真实条数与格式（当前一律 `-25211`/`-25204`）
- Chromium / Electron / 微信 / 飞书的菜单暴露完整度
- 滚动反向后触控板惯性是否受影响（代码上 `IsContinuous=true` 时零字段修改，预期无影响，需实测）

## 开发时的坑

| 坑 | 说明 |
|---|---|
| 每次重编译权限都失效 | ad-hoc 签名的 DR 就是当次 cdhash。`tccutil reset Accessibility dev.better-mac.app` 后重新授权 |
| `swiftc` 必须带 `-target` | 否则撞 CLT 里 SDK(6.3.2) 与编译器(6.3.3) 的 arm64e slice 不匹配，报错会误导成「SDK 不支持」 |
| 未授权时 API 返回值会骗人 | `tapCreate`/`addGlobalMonitor` 可能返回非 nil 但零投递。判断权限只能看 `AXIsProcessTrusted()` |
| `AXEnabled` 不可靠 | App 里禁用的菜单项，AX 仍可能报 `enabled=1`。跨 App 做不到「禁用项变灰」 |

## 调研

| 文件 | 内容 |
|---|---|
| [keystruck-teardown.md](research/keystruck-teardown.md) | KeyStruck 能做什么、官方承认的边界 |
| [pain-points.md](research/pain-points.md) | 36 条迁移痛点，🟢19 / 🟡13 / 🔴4，带证据分级 |
| [tech-feasibility.md](research/tech-feasibility.md) | 技术全景、竞品格局、分发路线、许可证雷区 |
| [build-spike.md](research/build-spike.md) | CLT-only 构建验证，18/18 项 |
| [ax-verified-facts.md](research/ax-verified-facts.md) | 亲手验证的 AX/CGEventTap 事实清单 |
| [ax-notification-dead-end.md](research/ax-notification-dead-end.md) | ⚠️ 推翻主路径的实测记录 |

## 下一步（需要你决定）

1. **授权一次，验证 L1 真的工作** —— 这是当前最大的未知
2. **Developer ID（$99/年）** —— 不是为了公证，是为了让 TCC 授权在迭代间稳定；也是发布 DMG 时用户不用右键绕过 Gatekeeper 的前提
3. **L2 的第二个修正项** —— `Correction` 协议已就位，加一个新痛点不用改 UI
4. **Windows 对照表** —— v2 的护城河，先填 20–30 条最高频动作

## 许可

MIT

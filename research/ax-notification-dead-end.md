# 实测发现：`AXMenuItemSelected` 在本机不可用

> 日期：2026-11-08 · 环境：macOS 26.4 arm64（Tahoe）· ad-hoc 签名 `.app` · `AXIsProcessTrusted=false`
> 这份记录推翻了 `tech-feasibility.md` 第 2.4 节「推荐组合」中的主路径。

## 结论

**`AXMenuItemSelected` 不能作为产品的主数据源。** 理由分两层，每层都有实测证据。

### 层 1：注册到菜单项上直接不支持

在 `AXMenuItem` 元素上调用 `AXObserverAddNotification(observer, item, kAXMenuItemSelectedNotification, nil)`，
**全部返回 `-25207`（`kAXErrorNotificationUnsupported`）**：

```
AXObserverCreate -> 0
addNotification on MENUBAR -> 0 OK
found 4 AXMenuItem(s)
addNotification on ITEM 'Quit' -> -25207 FAIL
addNotification on ITEM 'Quit and Keep Windows' -> -25207 FAIL
addNotification on ITEM 'Save' -> -25207 FAIL
addNotification on ITEM 'Copy' -> -25207 FAIL
```

这意味着「注册在每个菜单项上，回调里拿到具体是哪一个」这个思路**根本行不通**。
（`build-spike.md` 第 6 节其实已经观察到 `-25207`，但当时被当作「注册侧已验证」放过了。）

### 层 2：注册到 menuBar / App 上注册成功，但永不 fire

`menuBar` 和 `AXApplication` 上注册都返回 `0`。但真实触发菜单动作后 **0 条通知**：

**实验 A — 合成 ⌘S 键盘事件（走真实 menu key-equivalent 路径）**

```
register menubar AXMenuItemSelected -> 0
register APP AXMenuItemSelected -> 0
--- 现在合成 ⌘S 到自己的 App ---
  (Save action executed, count=1)
--- total AXMenuItemSelected fired = 0, didSave = 1 ---
```

动作**确实执行了**（`didSave=1`），但通知一条没有。

**实验 B — 用 AXPress 真按菜单项**

```
reg menubar -> 0
reg item -> -25207 UNSUPPORTED
AXPress result = 0
  (doSave ran)
--- fired=0 didSave=1 ---
```

`AXPress` 成功（返回 0）、动作执行了，通知仍然 0 条。

两次实验都是**自读自己进程**，不需要 TCC 授权，所以这些结果是干净的——
不存在「因为没授权所以收不到」的解释。

## 对实现的影响

原计划：观察菜单触发 → 得到动作名 → 弹吐司。（KeyStruck 自称的做法）

改为：**监听按键 + 反查菜单树**。

```
NSEvent.addGlobalMonitorForEvents(.keyDown)
        ↓  得到 KeyStroke(key: "S", modifiers: [.command])
MenuInventory.snapshot(pid)  ← 本来就是为「快捷键面板」建好的数据结构
        ↓  线性查找 key+modifiers 匹配项
Resolution(action: "Save", menuGroup: "File")
        ↓
HUDController.show(...)
```

### 为什么这条路反而更好

1. **同一个权限**：`addGlobalMonitorForEvents` 的键盘事件需要的是 **Accessibility**，
   不是 Input Monitoring（Apple 文档明写 "Key-related events may only be monitored
   if accessibility is enabled"）。和读菜单是同一个开关，用户体验上仍是「一个权限」。
2. **能看见「未绑定」**：监听按键让我们知道用户按了什么。
   观察菜单只知道「某个菜单项被触发了」——用户按了一个没绑定的键时，
   观察派什么都看不到，而监听派能说「这组键在这个 App 里没有对应动作」。
   对 Windows 迁移者，「我按了但没反应」恰恰是最需要解释的时刻。
3. **数据结构复用**：`MenuInventory` 本来就要为快捷键面板遍历菜单树，
   反查只是在同一个模型上做一次查找——零额外成本。

### 代价

- 必须过滤：不按修饰键的按键是打字，绝不能弹（已在 `handleKey` 里作为规则 1）。
- 不能知道「这个键触发了哪个**非菜单**动作」（那个本来也拿不到）。
- 系统级快捷键仍然看不到（macOS 在 App 之前拦截），和原方案一样。

## 仍未验证（需要人工授权）

以下都无法在无授权条件下测，**不要当成结论**：

1. 授权后 `addGlobalMonitorForEvents(.keyDown)` 的真实投递率。
2. 跨 App 读取菜单的真实条数（当前一律 `-25211` 或 `-25204`）。
3. Chromium / Electron / 微信 / 飞书的菜单暴露完整度。
4. 授权后 `AXMenuItemSelected` 是否在**跨 App** 场景下会 fire。
   （本报告只证明了**自读场景**下不 fire；跨 App 理论上走的是不同代码路径，
   但既然注册到菜单项上直接 `-25207`，「回调里拿到具体项」就不可能，
   所以即使跨 App 会 fire，也无法用于实现。）

第 4 条是这份报告最需要人工复核的一条。

## 复现

```bash
# 实验 A：合成 ⌘S 观察通知
/tmp/axfire/AXFire.app/Contents/MacOS/AXFire   # 见 /tmp/axfire/main.swift
cat /tmp/axfire/result.txt

# 实验 B：AXPress 观察通知
/tmp/axclick/AXClick.app/Contents/MacOS/AXClick
cat /tmp/axclick/result.txt
```

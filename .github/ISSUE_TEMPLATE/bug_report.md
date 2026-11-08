---
name: Bug 报告
about: 某个功能不工作、崩溃、或行为不对
title: '[Bug] '
labels: ['bug']
---

## 现象

<!-- 实际发生了什么？越具体越好。 -->

## 期望

<!-- 你以为会发生什么？ -->

## 复现步骤

1.
2.
3.

## 诊断日志

<!-- 这是定位问题最快的方式。没有它，大概率只能靠猜。 -->

```bash
cat ~/Library/Logs/better-macOS.log
```

```text
（把日志粘贴在这里）
```

## 环境

- macOS 版本：
- 芯片（Apple Silicon / Intel）：
- better-macOS 版本（菜单栏 → 设置 里能看到，或 `git log -1`）：
- 是怎么启动的：
  - [ ] 双击 / Finder
  - [ ] `open /Applications/better-macOS.app`
  - [ ] 直接执行 `Contents/MacOS/better-macOS`

> ⚠️ 如果是「功能不工作」，**启动方式是关键信息**。
> 从终端直接执行二进制会继承终端的授权，日志里的 `trusted=true` 是假的；
> 只有经 `open` / Finder / Dock 启动才反映真实权限状态。

## 是否已授权辅助功能

- [ ] 已授权，且拖拽引导里显示的也是「已授权」
- [ ] 已授权，但 App 里仍显示未授权
- [ ] 未授权

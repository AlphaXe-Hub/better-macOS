# AX 探针

用来回答 issue #6「微信 / Electron 系菜单读取失败」的实测工具。
它不是产品的一部分，只在需要重新取证时跑。

## 跑法

```bash
./scripts/ax-probe/run.sh                              # 默认：微信/飞书/Obsidian/Chrome/Safari/Finder
./scripts/ax-probe/run.sh --app "微信,飞书" --n 10      # 指定 App 与次数
./scripts/ax-probe/run.sh --timeouts 0.5,2,5           # 对比不同 messaging timeout
```

`--cold` 模式需要先手动 `open` 目标 App（见下面「冷启动怎么测」）。

## ⚠️ 为什么探针的结论要打折扣

从终端跑会**继承终端的辅助功能授权**，`AXIsProcessTrusted()` 返回 `true`
（README「开发时的坑」里写过）。所以探针测到的是**最大授权**状态：

- 好处：把「权限」这个变量彻底排除，任何失败都只能是 App 自身的行为；
- 代价：**探针复现不出「真没授权」导致的 `noPermission`**。
  那条路径要靠「装成 App、从 Finder 打开、不授权」来验。

## 冷启动怎么测

Electron 系 App 冷启动时有一个「进程已经在了、但菜单栏还没建好」的窗口期。
这个窗口期**不是每台机器每次都会出现**（本机实测 0.01s / 0.36s / 0.38s / 4.7s 都有），
所以要重试多次才有意义：

```bash
pkill -f "飞书.app/Contents/MacOS"; sleep 3
open -a /Applications/飞书.app
# 立刻反复跑：
./scripts/ax-probe/run.sh --app 飞书 --n 5
```

判据只有一个：**看耗时**。

| 现象 | 含义 |
|---|---|
| `err=success` | 正常 |
| `err=-25204 cannotComplete`，耗时 **≈ timeout** | App 真的忙/卡住（可以用 `kill -STOP <pid>` 稳定复现） |
| `err=-25204 cannotComplete`，耗时 **0.1~0.3ms** | 菜单栏还没建好（冷启动），或这个进程根本不是 GUI App |
| `err=-25211 apiDisabled` | 没有辅助功能授权 |

这两类 `-25204` 混在一起，就是 #6 被误诊成「微信不支持」的原因。

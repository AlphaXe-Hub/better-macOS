# 分发：DMG、公证、自动更新

> 对应 issue #7。**结论先说**：DMG 打包已经能用了；公证和 Sparkle 卡在同一个前提上——
> Developer ID 证书（$99/年）。本文把「现在能做什么」和「必须花钱才能做什么」分开写清楚。

## 现状：一张表

| 能力 | 状态 | 依赖 |
|---|---|---|
| 构建 `.app`（CLT-only，无需 Xcode） | ✅ 已完成 | 无 |
| 打成 DMG（带 Applications 软链） | ✅ 已完成 `./scripts/make-dmg.sh` | 无 |
| 本机开发签名稳定（不用每次重授权） | ✅ 已完成 `./app/setup-devcert.sh` | 无 |
| **他人机器双击即用** | ❌ **做不到** | **Developer ID（$99/年）** |
| 公证（notarytool + stapler） | ⚠️ 脚本就绪，无证书跑不通 | Developer ID |
| Sparkle 自动更新 | ⚠️ 未接入 | 先解决签名，否则更新包也过不了 Gatekeeper |

**不要自我欺骗**：没有 Developer ID，用户在别人机器上一定会看到「无法打开，因为 Apple 无法验证」。
这不是 bug，是 Apple 对未公证产物的强制拦截。绕过它的唯一"办法"是教用户右键 → 打开，
但那把一个安全门槛变成了安装说明，对「让 Windows 用户丝滑迁移」的定位是直接伤害。

## 一、DMG（现在就能用）

```bash
./app/build.sh release      # 先构建
./scripts/make-dmg.sh       # 产出 dist/better-macOS.dmg
```

脚本做的事，以及为什么这么做：

- **用 `hdiutil` 而不是 `create-dmg`**：后者要 `brew install`，把简单的事藏进一层黑箱。
  出问题时 `hdiutil` 的错误信息你能查、能改。
- **临时镜像放在 `mktemp -d` 里，绝不放进被镜像的目录**。踩过：把 `$RW` 放进 `$STAGE`，
  `hdiutil` 会试图把正在写的镜像自己打进镜像，直接失败。
- **烧 Finder 图标布局时给了硬超时**。`osascript` 驱动 Finder 需要「自动化」授权，
  那个授权框在某些会话里根本弹不出来，脚本会无限挂起——比丑图标的代价大得多。
  所以超时就跳过美化，明确打印「不影响可用性」。
- **产物自带说明**：签名不是 Developer ID 时，脚本会主动警告这份 DMG 在别人机器上的行为。

实测（macOS 26.4 / arm64）：产物 1.6 MB，`UDZO` 格式，`hdiutil verify` 通过，
挂载后结构完整（`Applications` 软链、`Info.plist` 里 `LSUIElement=true`、`codesign -v` 自洽）。

> 大小参考：`research/tech-feasibility.md` 里测算过「不带驱动与 Helper 的纯 Swift 菜单栏工具，
> dmg 在 5–7 MB 量级」。我们 1.6 MB，因为没有第三方框架且图标之外没有资源。

## 二、公证（脚本就绪，等证书）

```bash
export NOTARY_PROFILE=better-macOS-notary
./scripts/notarize.sh dist/better-macOS.dmg
```

`scripts/notarize.sh` 会**先做前置检查再提交**，因为 notarytool 一次提交要等几分钟，
让用户等完才发现「证书类型不对」是很糟的体验。三道检查：

1. **签名身份必须是 `Developer ID Application`**。自签名和 ad-hoc 都会被公证服务直接拒。
2. **不能有 `get-task-allow` entitlement**。这是 Apple 明令禁止出现在发布产物里的，
   带了必拒。
3. **凭据**：keychain profile 或三个环境变量，密码是 App 专用密码（不是 Apple ID 密码）。

通过后自动 `stapler staple` + `stapler validate`，最后用 `spctl` 做一次冒烟。

**一个容易踩的坑**：`.app` 不能被直接提交公证（Apple 文档原话 "you can't upload the .app
bundle directly"）。必须先打成 dmg 或 zip。装订同理——对 dmg 装订，票据才会跟着分发走。

**公证流程本身不需要 Xcode**，`notarytool` / `stapler` 都在 CLT 里。这条已在本机验证
（`xcrun notarytool --version` → 1.1.2）。

## 三、拿到 Developer ID 之后要改的地方

1. **`app/build.sh` 的签名段**：把 `better-macOS Dev` 换成 `Developer ID Application: ...`，
   并加上 `--options runtime`（Hardened Runtime，公证的硬性要求）。
   `--deep` 应尽早去掉——它是给不规整 bundle 的补丁，会让 entitlements 处理变得不可预测。
2. **`scripts/make-dmg.sh` 的结尾判断**：它已经在检测 `Developer ID Application`，
   拿到证书后会自动换成分发口径的提示，不用改。
3. **CI**：`.github/workflows/release.yml` 需要三个 secret：
   `BUILD_CERTIFICATE_BASE64` / `P12_PASSWORD` / `KEYCHAIN_PASSWORD`，
   加上公证凭据 `APPLE_ID` / `TEAM_ID` / `APP_SPECIFIC_PASSWORD`。
   **证书绝不能进仓库**，只能进 Actions secrets。

## 四、Sparkle 自动更新

**为什么现在不做**：Sparkle 自己用 EdDSA 签名，理论上与 Apple 证书无关——
但**更新包本身仍要过 Gatekeeper**。也就是说，没有 Developer ID 的话，
自动更新下载下来的新版本一样会被拦。先解决签名，Sparkle 才有意义。

已知的工程约束（来自 `research/tech-feasibility.md`，本机实测过）：

- 不能只加 SwiftPM 依赖了事：手工打包必须把 `Sparkle.framework` 放进 `Contents/Frameworks`、
  加 `-Wl,-rpath,@loader_path/../Frameworks`、**保留符号链接与可执行位**
- Hardened Runtime + ad-hoc 签名下 Sparkle 可能加载不了

所以正确的顺序是：**Developer ID → 公证 → Sparkle**。倒过来做等于在流沙上盖楼。

## 五、App Sandbox / App Store 路线：封死

不是懒得做，是**技术上不可能**：

- AX（辅助功能）API 与 App Sandbox 不兼容，Apple DTS 已明确表态
- Mac App Store 要求必须沙箱
- MAS 还要求必须用 Xcode 打包、更新必须走 MAS 自己的通道

本产品的两个核心能力（读别家 App 的菜单树、改滚动事件）都在沙箱白名单之外。
这条路彻底不通，不要再花时间评估。

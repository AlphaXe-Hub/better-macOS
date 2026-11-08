# Windows → macOS 迁移痛点系统聚合

> 研究对象：从 Windows 迁移到 macOS 的**具体摩擦点**，用于指导菜单栏 App「better-macOS」的功能取舍。
> 采集时间：2026-11。调研机为 macOS 26.4（Tahoe），关键结论在本机做过一手验证。
> 组织方式：按领域分表，每条含「短标题 / 现象 / 证据 / 现有解法 / 可解性判断」，共 **36 条**。

## 0. 方法与证据分级

- **证据分级**：`[R]` = 用户真实抱怨（Reddit 帖子/评论、Ask Different 提问、知乎正文及评论区），**权重最高，立项只看这一档**；`[B]` = 博主/编辑部整理的清单或教程，仅用于发现关键词与补全现象，不单独作为依据；`[A]` = Apple 官方文档，用来**校准行为事实**（"Mac 到底怎么做的"），不作为痛点存在性证据。
- **判定口径**：🟢 纯软件可解（本 App 能做）· 🟡 需 hack / 部分可解 / 依赖 Accessibility、Input Monitoring 等敏感权限 · 🔴 不可解或不该做。
- **取证方式**：Reddit 通过 `.rss` 端点抓取（含楼层评论原文）；Ask Different 通过 Stack Exchange API 检索（返回的 `link` 即下表链接，赞数/浏览量取自 API）。
- **一手验证**：对最关键的 M1（自然滚动无法按设备分开），直接用 `defaults` 查了系统偏好键，不是转述二手结论。

### 0.1 链接核验结果（2026-11-08 全量复查）

对全文 88 处引用做了可解析性核验，结论：

| 来源 | 数量 | 核验方式 | 结果 |
|---|---|---|---|
| `apple.stackexchange.com` | 35 条独立问题 | Stack Exchange API 批量取 `score`/`title` | **35/35 存在，且文中所标赞数与 API 返回值逐条一致** |
| `reddit.com` 帖子 | 24 条独立帖子 | Arctic Shift 归档 API 按 ID 取回 `title`/`score`/`comment_count` | **24/24 存在**；标题与文中引用语境一致（部分帖子分数很低但标题即证据，见下） |
| `support.apple.com` | 7 条官方文档 | HTTP 直连 | **7/7 返回 200** |
| `sspai.com` | 1 篇（post/104699） | 抓正文全文 | **可读**，确实支撑 S3 与 O2（见 0.2） |
| `zhuanlan.zhihu.com` / `zhihu.com` | 4 条 | HTTP 直连 | **403（知乎反爬墙），正文无法核对**，相关条目仅凭标题引用，已按 `[B]` 处理 |

> 关于 Reddit 低分帖：W1/W2 引用的 `1w6oblj`（26 分）、K4 引用的 `1ttul8b`（0 分）**分数不高，但标题本身即完整证据**（"Home end keys — my biggest complaint since switching from windows"），且评论数（141/21）说明有真实讨论。引用它们是因为"标题直接命中痛点"，而非因为热度——这一点请勿误读为"高赞证据"。

### 0.2 本机一手复验（与上文条目对应）

在调研机（macOS 26.4 Tahoe）上实测，用于校准"系统到底有没有这个开关"：

| 检查项 | 命令 | 实测结果 | 对应结论 |
|---|---|---|---|
| 滚动方向是否全局唯一 | `defaults read -g com.apple.swipescrolldirection` | `0`（**单一布尔值**，无 per-device 维度） | M1 成立：系统层只有全局开关 |
| 触控板域有无方向键 | `defaults read com.apple.AppleMultitouchTrackpad` | 只有 `TrackpadScroll`/`TrackpadHorizScroll`/`TrackpadMomentumScroll`，**无任何 `ScrollDirection*` 键** | M1 成立：连隐藏项都没有 |
| 鼠标域有无方向键 | `defaults read com.apple.AppleMultitouchMouse` | 同上（`MouseVerticalScroll` 等，**无方向键**） | M1/M6 成立 |
| 鼠标加速曲线 | `defaults read -g com.apple.mouse.scaling` | **不存在该键**（未设置） | M2 的"不可控"属实：无持久化曲线配置 |
| F 键默认态 | `defaults read -g com.apple.keyboard.fnState` | **不存在该键** → 未开启"标准功能键" | K6 成立：默认媒体键 |
| 输入法切换热键 | `plutil -extract AppleSymbolicHotKeys.60/61` | 两项**均存在且 enabled=true**，参数 `32/49/262144` 与 `32/49/786432`（keycode 49 = Space，modifier 262144 = ⌃） | K8 成立：默认 ⌃Space / ⇧⌃Space |

> 复验价值：M1 这条不再依赖任何二手说法——**Apple 的系统偏好里物理上就不存在"按设备设置滚动方向"的键**，这是本项目最硬的一条立项依据。

## 1. 键盘与输入法

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有解法 | 判断 |
|---|---|---|---|---|---|
| K1 | **Ctrl ↔ Command 位置错乱** | Win 上复制粘贴是左手小指按 Ctrl + 食指 C；Mac 换成 ⌘，且 ⌘ 紧贴空格，同一套手型按下去变成"手指打结"。有人干脆想要"全部操作都用 Windows 风格快捷键"。 | [R] [Ask Different 47 赞：能不能把 macOS 改成 Windows 风格快捷键](https://apple.stackexchange.com/questions/312656/how-can-i-reprogram-osx-to-use-windows-style-shortcuts-for-all-operations)、[R] [r/macbookpro "cut and paste 像扭麻花"](https://www.reddit.com/r/macbookpro/comments/oo9eia/)、[R] [r/MacOS 双系统用户：第一件事就是对调两键](https://www.reddit.com/r/MacOS/comments/1lun8x3/) | 系统「键盘 → 修饰键」可对调；但**整机对调**会连 ⌘Q/⌘W/⌘Tab 一起反过来，看教程全对不上。Karabiner 可做按 App 映射 | 🟡 |
| K2 | **Alt 不是 Option，还会输特殊字符** | Win 的 Alt 是功能键（Alt+Tab、Alt+方向键按词跳）；Mac 的 Option 兼作字符输入，按 ⌥+→ 不是"按词移动"而是乱跳或插入符号 | [R] [Ask Different 27 赞：让 Option+方向键像 Win 的 Ctrl+方向键](https://apple.stackexchange.com/questions/22674/make-mac-os-x-option-arrow-work-like-windows-ctrl-arrow)、[R] [按特定键盘对调 ⌥/⌘](https://apple.stackexchange.com/questions/263983/is-it-possible-to-swap-option-and-command-keys-for-a-specific-keyboard) | 无系统级"按词移动"映射；Karabiner 可重绑 | 🟢 |
| K3 | **Delete 键不是"向后删"** | Win 的 Delete 删光标后一个字；Mac 主键位上的 delete 等于退格，真正的向后删要按 Fn+Delete | [R] [r/MacOS：Fn+Backspace 才是 PC 的 Delete](https://www.reddit.com/r/MacOS/comments/5u61r9/)、[R] [外接键盘 delete 键行为诡异](https://apple.stackexchange.com/questions/7310/strange-behaviour-from-delete-key-on-a-non-apple-keyboard) | 系统无开关；Karabiner 改键 | 🟢 |
| K4 | **Home/End/PgUp/PgDn 语义不同** | Win 的 Home/End 跳行首行尾、PgUp/PgDn 翻页；Mac 上 Home/End 常跳到文档首尾，笔记本上干脆没这几个键，翻页要 Fn+↑/↓。Magic Keyboard 的 Home/End 还被映射成 Page Up/Down | [R] **[Ask Different 590 赞 / 23 万浏览：把 Home/End 改成行首行尾](https://apple.stackexchange.com/questions/16135/remap-home-and-end-to-beginning-and-end-of-line)**（**全站票数第 8、keyboard 标签下第 2，23.1 万次浏览**——按 2026-11-08 API 实测排名，不是修辞）、[R] [r/MacOS "Home end keys — 我换机后最大的抱怨"](https://www.reddit.com/r/MacOS/comments/1ttul8b/)、[R] [r/MacOS：Home/End/PgUp/PgDn 没什么用](https://www.reddit.com/r/MacOS/comments/pz9vnu/)、[R] [Magic Keyboard 的 Home/End 变成翻页](https://apple.stackexchange.com/questions/440781/magic-keyboard-home-and-end-keys-acts-as-page-up-and-page-down) | ⌘←/⌘→ 替代行首尾；Fn 组合；`defaultkeybinding.dICT` 可改但门槛高 | 🟡 |
| K5 | **Win 键 → ⌘ 的物理位置** | 外接 Windows 键盘时 Win 键被识别为 ⌘，但它在 Ctrl 左边，和 Mac 内置键盘的 ⌘ 位置正好相反，形成"同一台机器两套肌肉记忆" | [R] [Ask Different 14 赞：Win 键没有自动映射成 ⌘](https://apple.stackexchange.com/questions/159723/mac-osx-not-automatically-remapping-windows-key-to-cmd)、[R] [外接键盘与内置键盘分开重映射](https://apple.stackexchange.com/questions/94903/how-can-i-remap-keys-on-an-external-keyboard-but-keep-the-default-layout-on-the) | 修饰键可**按键盘**分别配置 | 🟢 |
| K6 | **F1–F12 默认是媒体键** | Win 上 F2 是重命名、F5 刷新；Mac 上 F1/F2 调亮度、F3 调度中心，要按 Fn 才是真 F 键。且不同 App 需求相反（IDE 要真 F 键、看片要媒体键） | [R] [Ask Different：能否只对某些 App 用标准功能键](https://apple.stackexchange.com/questions/49315/can-i-use-my-f1-f2-etc-keys-as-standard-function-keys-only-for-specific-apps)、[R] [r/MacOS 升级后 F 键行为异常](https://www.reddit.com/r/MacOS/comments/16xrh5o/) | 系统「将 F1/F2 用作标准功能键」是**全局开关**（本机 `com.apple.keyboard.fnState` 未设置=默认媒体键）；无按 App 切换 | 🟡 |
| K7 | **截图快捷键体系完全不同** | Win 是 PrtSc / Win+Shift+S 一步完成；Mac 是 ⇧⌘3 / ⇧⌘4 / ⇧⌘5，截窗口还要按空格，且默认**存成文件到桌面**而非进剪贴板（要加 ⌃）。PrtSc 这个键在 Mac 键盘上不存在 | [A] [Apple：截屏快捷键全表](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac)、[R] [r/mac "怎样截屏更顺手"](https://www.reddit.com/r/mac/comments/1nbwahk/) | 系统可自定义组合键；"存文件 vs 进剪贴板"默认值无开关 | 🟢 |
| K8 | **输入法切换键与状态提示** | Win 是 Shift 或 Ctrl+Space 切中英、托盘有常驻语言栏；Mac 默认 Ctrl+Space（本机 `com.apple.symbolichotkeys` 60/61 可确认），切完**只有菜单栏小图标**，且 Caps Lock 切输入法有已知延迟 | [R] [Ask Different：Caps Lock 切输入法有延迟](https://apple.stackexchange.com/questions/440928/disable-lag-when-using-caps-lock-key-to-toggle-input-language)、[R] [75 赞：如何给切换输入源设快捷键](https://apple.stackexchange.com/questions/135370/how-can-i-set-up-a-keyboard-shortcut-for-switching-input-source) | 系统可改键位；状态可视化需第三方浮层（易误判） | 🟡 |
| K9 | **Win+Space 与 ⌘Space 撞车** | Win 上 Win+Space 切输入法；Mac 上 ⌘Space 被 Spotlight 占用，按下去弹搜索框而不是切输入法 | [B] [知乎：两套系统键位怎么统一](https://www.zhihu.com/question/301575364) | 改 Spotlight 快捷键或改输入源快捷键，需自己试 | 🟢 |

## 2. 窗口管理

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有解法 | 判断 |
|---|---|---|---|---|---|
| W1 | **⌘Tab 只切 App，不切窗口** | Win 的 Alt+Tab 在**窗口**间切；Mac 的 ⌘Tab 是**应用**切换器，同一 App 开三个文档只会到"最近那个"，同 App 内切窗口要 ⌘\` | [R] [r/MacOS "用了三年 Mac 仍觉得自己像白痴"](https://www.reddit.com/r/MacOS/comments/1w6oblj/)、[R] [r/MacOS：为什么 ⌘Tab 不是窗口切换器](https://www.reddit.com/r/MacOS/comments/m6zlmu/)、[R] [知乎：最不习惯的不是快捷键，是找窗口](https://zhuanlan.zhihu.com/p/2072985238423204478) | AltTab / Contexts / Raycast；⌘\` 兜底 | 🟡 |
| W2 | **最小化窗口 ⌘Tab 唤不回** | Win 上点任务栏图标就还原最小化窗口；Mac 上 ⌘Tab 选到该 App 后**什么都不会发生**，必须松开 Tab、按住 Option、再松 ⌘ 才拉得回来——这套组合逻辑新手几乎摸不出来 | [R] [r/MacOS：最小化后 ⌘Tab 不显示窗口](https://www.reddit.com/r/MacOS/comments/m6zlmu/)、[R] [r/MacOS 同主题高赞："这设计蠢透了"](https://www.reddit.com/r/MacOS/comments/1w6oblj/)、[R] [知乎：这套组合新手摸不透](https://zhuanlan.zhihu.com/p/2072985238423204478) | 无系统设置；AX + AppleScript 可强制 unminimize | 🟢 |
| W3 | **关闭窗口 ≠ 退出程序** | Win 上点 × 就是关程序；Mac 上红叉只关窗口，App 仍驻留 Dock（⌘Q 才退出）。于是"以为关了其实还在跑""后台一堆 App" | [R] [r/MacOS 迁移帖，高赞解释红叉语义](https://www.reddit.com/r/MacOS/comments/1dnbpk8/)、[R] [r/mac "15 年 Windows 用户换 Mac"](https://www.reddit.com/r/mac/comments/18vczdo/) | 系统无此选项；第三方可做"关窗即退出"，但会破坏 Mac 语义（用户自己都说"有些 App 就是想留着"） | 🟡 |
| W4 | **绿灯是"全屏"不是"最大化"** | Win 上双击标题栏/点 □ 是最大化铺满工作区；Mac 绿点进入**全屏空间**（菜单栏 Dock 消失、有动画），该 App 从此不在当前桌面里。用户要的是"铺满但别全屏" | [R] [Ask Different 152 赞：如何改绿灯默认行为](https://apple.stackexchange.com/questions/151734/how-to-change-the-default-behaviour-of-the-fullscreen-maximize-button)、[R] [Ask Different：到底怎么最大化窗口](https://apple.stackexchange.com/questions/2680/how-do-you-maximize-windows)、[R] [r/MacOS：怎么改绿灯默认值](https://www.reddit.com/r/MacOS/comments/1p936qm/) | 按住 ⌥ 点绿灯 = Zoom（铺满）；无全局默认值 | 🟡 |
| W5 | **双击标题栏缩放默认没开** | Win 双击标题栏=最大化；Mac 默认"最小化"甚至什么都不做，要自己去「桌面与程序坞」改成"缩放" | [R] [r/MacOS：只能靠系统设置改双击标题栏](https://www.reddit.com/r/MacOS/comments/14sgwf5/)、[A] [Apple：桌面、菜单栏与程序坞](https://support.apple.com/guide/mac-help/desktop-menu-bar-and-dock-mchlws12345m2/27/mac/27) | 系统设置已有该开关，只是默认不符合 Win 习惯 | 🟢（系统已覆盖） |
| W6 | **第一次点击只激活，不生效** | Win 上未聚焦窗口里的按钮，点一下就生效（click-through）；Mac 上第一下通常只把窗口提到前面，第二下才点到按钮 | [R] [Ask Different 29 赞：能否全局开启 click-through](https://apple.stackexchange.com/questions/34446/enable-click-through-preferrably-for-all-applications)、[R] [应用首次聚焦时的双击问题](https://apple.stackexchange.com/questions/92644/prevent-double-click-on-application-focus) | 无系统开关；只能靠 AX + 合成事件 hack，稳定性差 | 🟡 |
| W7 | **"我的电脑 / 资源管理器"在哪** | Win 找盘的路径是"此电脑 → D 盘"；Mac 没有盘符，要开 Finder 再 ⌘⇧C 找宗卷，路径概念整套换掉 | [R] [r/mac 迁移帖：Explorer = Finder，但没有地址栏](https://www.reddit.com/r/mac/comments/18vczdo/) | Finder 侧边栏 / ⌘⇧C 宗卷 / 「前往 → 前往文件夹」 | 🟢 |
| W8 | **贴边分屏来得太晚且弱** | Win 上拖到边缘就 1/2、1/4 停靠，是十几年习惯；macOS 直到 Sequoia 才有窗口平铺（拖边缘 / ⌥拖拽 / 菜单 / 快捷键），且没有 Win 那种四分屏直觉 | [A] [Apple：平铺窗口的官方做法](https://support.apple.com/guide/mac-help/tile-app-windows-mchlef287e5d/27/mac/27)、[R] [Ask Different：分屏快捷键诉求](https://apple.stackexchange.com/questions/309708/shortcuts-for-full-screen-split-view) | 系统自带平铺 + Magnet / Rectangle / Raycast | 🟢（系统已覆盖大半） |

## 3. 文件管理

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有解法 | 判断 |
|---|---|---|---|---|---|
| F1 | **Finder 没有"剪切"文件** | Win 是 Ctrl+X → Ctrl+V 移动；Mac 上 ⌘X 对文件无效，必须 ⌘C 再 ⌥⌘V（"移动到此处"），全靠硬记 | [R] [Ask Different 212 赞：为什么 Finder 不能剪切文件](https://apple.stackexchange.com/questions/12391/why-is-it-not-possible-to-use-the-cut-command-to-manipulate-a-file-in-the-find)、[R] [r/macbookair 迁移吐槽："Finder 没有正常剪切"](https://www.reddit.com/r/macbookair/comments/1xdxh24/)、[R] [r/MacOS：剪切/粘贴的语义讨论](https://www.reddit.com/r/MacOS/comments/1s27gay/) | ⌥⌘V 兜底；Finder 扩展/右键服务可补 | 🟡 |
| F2 | **右键菜单没有"新建文件"** | Win 右键 → 新建 → 文本文档；Mac 右键只能新建文件夹，建空文件要么开终端 `touch`，要么先开 App 另存 | [R] [Ask Different：Finder 右键的 "New Item"](https://apple.stackexchange.com/questions/320458/new-item-in-finders-right-click-menu)、[R] [Ask Different：自定义右键菜单项](https://apple.stackexchange.com/questions/104021/how-can-i-create-custom-right-click-context-menu-items-in-macos) | 第三方（New File Menu / 超级右键 / Finder 扩展） | 🟢 |
| F3 | **看不到也复制不了路径** | Win 资源管理器有地址栏，可点可复制；Finder 默认只有路径栏，还要 ⌥ 点路径栏才能复制，⌘⇧G 前往路径是新概念 | [R] [Ask Different 23 赞：能否编辑/查看 Finder 路径](https://apple.stackexchange.com/questions/63791/is-it-possible-to-edit-the-path-and-view-the-folder-path-in-the-finder)、[R] [40 赞：如何把路径当字符串复制](https://apple.stackexchange.com/questions/252171/mac-finder-getting-the-path-of-a-directory-or-file-as-as-string) | 显示路径栏 + ⌥ 点路径 | 🟢 |
| F4 | **隐藏文件的开关是"魔法键"** | Win 是资源管理器里"显示隐藏项"的复选框；Mac 是 ⌘⇧. 这个组合，没人告诉你就不可能知道 | [R] [Ask Different 22 赞：不用终端显示隐藏文件](https://apple.stackexchange.com/questions/258733/how-to-show-hidden-files-on-mac-without-terminal) | ⌘⇧. | 🟢（系统已覆盖） |
| F5 | **NTFS 只能读不能写** | Win 用户的 U 盘/移动硬盘多为 NTFS，插到 Mac 上能看能拷出，但**写不进去**，工作交接时极易踩坑 | [R] [Ask Different 70 赞：如何写 NTFS](https://apple.stackexchange.com/questions/20889/how-do-i-write-to-ntfs-drives-in-os-x)、[R] [r/MacOS：为什么 macOS 不支持 NTFS 写入](https://www.reddit.com/r/MacOS/comments/1kk0v7b/)、[R] [r/mac："NTFS 在 Mac 上只读，要用可疑的第三方软件"](https://www.reddit.com/r/mac/comments/1pjtus3/) | 第三方 NTFS 驱动（付费）、格式化为 exFAT | 🔴（需 root/内核扩展，与 SIP 冲突，不该做） |
| F6 | **卸载 App 留一地残渣** | Win 有"卸载程序"入口；Mac 是拖到废纸篓，但 `~/Library` 下的配置、缓存、LaunchAgents 全留下 | [R] [Ask Different 33 赞：Zoom 卸不干净](https://apple.stackexchange.com/questions/358651/unable-to-completely-uninstall-zoom-meeting-app)、[A] [Apple：安装与卸载 App](https://support.apple.com/guide/mac-help/install-and-uninstall-other-apps-mh35835/27/mac/27) | AppCleaner / Pearcleaner | 🟢 |
| F7 | **RAR/7z 双击打不开** | Win 装个 WinRAR 就通吃；Mac 原生归档工具只认 zip，从 Windows 拷来的 .rar 直接卡住 | [B] 知乎专栏（`p/2066200082072991428`，**页面需登录，仅能确认标题存在，正文未核对**，故降为 B 档） | The Unarchiver / Keka / `unar` | 🟡 |
| F8 | **回车键是"重命名"不是"打开"**（补充，原 36 条遗漏） | Win 上选中文件按 Enter = 打开，是 Finder 里最本能的动作；Mac 上选中文件按 Enter = **进入重命名状态**，打开要 ⌘O。迁移用户在 Finder 里连按几次回车会把文件名全改坏 | [R] [Ask Different：选中文件按 Enter，它想重命名我](https://apple.stackexchange.com/questions/348819/can-we-open-run-a-file-executable-in-finder-using-the-keyboard)（原话 "In Finder, if a file is selected and we press Enter, it wants to rename the file"）、[R] [Ask Different：Enter 想当 ⌘O 用](https://apple.stackexchange.com/questions/8507/enter-return-key-as-cmd-o)、[R] [r/mac：只用键盘怎么打开文件？](https://reddit.com/r/mac/comments/vhchkf/basic_how_open_file_through_finder_using_the/) | 系统设置 → 键盘 → 键盘快捷键 → App 快捷键，可给 Finder 的「打开」加 ⌘↵（社区公认做法）；**但没人能取消 Enter=重命名**，只能叠加 | 🟢（可做，且是纯软件、无权限门槛的空白项） |

## 4. 鼠标 / 触控板 / 滚动

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有解法 | 判断 |
|---|---|---|---|---|---|
| M1 | **自然滚动把鼠标和触控板绑死**（已知核心痛点） | 触控板要"内容跟手指走"（自然滚动），滚轮鼠标却要"滚轮往下=页面向下"（传统方向）。macOS 只有一个开关，两边需求相反，插拔鼠标就得来回改 | **本机一手验证**：`defaults read -g com.apple.swipescrolldirection` 只有一个全局值；`com.apple.AppleMultitouchTrackpad` 域内**没有任何** `ScrollDirection*` 键 → 系统层只有全局开关。[R] [r/mac：分开设置后方向还是镜像的](https://www.reddit.com/r/mac/comments/1koh28t/)、[R] [r/MacOS：为什么鼠标滚动方向被绑到触控板上](https://www.reddit.com/r/MacOS/comments/x7zvya/)、[R] [**Ask Different 726 赞、全站票数第 4、13 个回答**：如何分开鼠标与触控板设置](https://apple.stackexchange.com/questions/116617/how-to-separate-mouse-and-trackpad-settings)、[R] [r/apple："两个设备只有一个滚动开关"](https://www.reddit.com/r/apple/comments/zlurhe/how_has_apple_still_not_fixed_natural_scrolling/) | Scroll Reverser（开源，按设备区分）、LinearMouse（按设备+按 App）、Mac Mouse Fix；Apple 官方文档只承认"自然滚动"一个选项 | 🟢 |
| M2 | **鼠标加速曲线不可控** | Win 是"提高指针精确度"一个勾，可关；macOS 加速度激进且长期**只有开关没有曲线**，画图/打游戏时手感飘 | [R] [Ask Different 84 赞：改滚轮加速](https://apple.stackexchange.com/questions/23189/change-the-mouse-wheel-scrolling-acceleration)、[R] [18 赞：关闭鼠标加速](https://apple.stackexchange.com/questions/7201/disable-mouse-acceleration) | LinearMouse / SteerMouse；macOS 26 系统设置里已有"指针加速"开关 | 🟢 |
| M3 | **指针速度上限不够** | Win 有 11 档 + 注册表可超频；Mac 滑块拉满仍嫌慢，大屏/高分屏用户尤其明显 | [R] [Ask Different 74 赞：如何超过最大追踪速度](https://apple.stackexchange.com/questions/15210/how-to-increase-tracking-speed-beyond-the-maximum) | 第三方写 IOHIDSystem 参数 | 🟢 |
| M4 | **中键 / 侧键无处映射** | Win 上中键开新标签、侧键前进后退是本能；Mac 默认中键几乎没用途，侧键在系统设置里也不可改 | [R] [Ask Different：中键偶尔失效](https://apple.stackexchange.com/questions/270626/middle-mouse-button-stops-working-from-time-to-time)、[B] [LinearMouse 的按键映射定位](https://linearmouse.app/en/) | Mac Mouse Fix / BetterTouchTool / LinearMouse | 🟢 |
| M5 | **滚轮一格跳太远/太"糊"** | Win 滚轮是"一格滚 3 行"；Mac 滚动是惯性+加速的连续事件，滚轮鼠标在上面要么飞要么粘，平滑度不可调 | [R] [Ask Different 84 赞：滚轮加速问题](https://apple.stackexchange.com/questions/23189/change-the-mouse-wheel-scrolling-acceleration)、[R] [Logitech 平滑滚动过度](https://apple.stackexchange.com/questions/324794/logitech-mx-anywhere-2-mouse-smooth-scrolling-mode-is-overly-active) | Mos（平滑滚动）、Scroll Reverser 的"步进"选项 | 🟡 |
| M6 | **换设备就换一套设置** | 办公室用鼠标、沙发用触控板、偶尔插别人的键盘——Win 上各设备各自记忆；Mac 多为一套全局设置，切设备就要重设 | [R] [r/MacOS：两台设备一个滚动设置](https://www.reddit.com/r/MacOS/comments/x7zvya/)、[R] [r/mac：外接鼠标与内置触控板冲突](https://www.reddit.com/r/mac/comments/cxzb9n/)、[B] [按设备做配置的实践](https://hayorov.me/posts/macos-scroll-direction-linearmouse/) | LinearMouse 的 device profile | 🟢 |

## 5. 系统与界面

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有工具/现状 | 判断 |
|---|---|---|---|---|---|
| S1 | **菜单栏随前台 App 变化** | Win 的应用菜单在窗口内部，位置固定；Mac 的菜单栏属于当前 App，切走就整条换掉，"我要找的那个菜单去哪了" | [A] [Apple：桌面、菜单栏与程序坞](https://support.apple.com/guide/mac-help/desktop-menu-bar-and-dock-mchlws12345m2/27/mac/27)、[R] [知乎：两套窗口管理逻辑的根本差异](https://zhuanlan.zhihu.com/p/2072985238423204478) | 系统设计；可做"菜单项搜索"辅助（Help 菜单可搜） | 🔴（不该改） |
| S2 | **Dock 没有窗口预览** | Win 任务栏悬停出缩略图，可一步跳到某个窗口；Mac Dock 悬停只有 App 名，单击是把整个 App 抬起来，不帮你定位到具体窗口 | [R] [知乎：Dock 悬停不弹预览，只能整体唤起](https://zhuanlan.zhihu.com/p/2072985238423204478) | DockDoor / HyperDock 类（AX + 窗口列表） | 🟡 |
| S3 | **菜单栏图标装不下（刘海/小屏）** | Win 有托盘溢出面板；Mac 没有官方收纳机制，图标一多就被刘海或右侧吃掉，Apple 长期不给方案 | [R] [Ask Different 68 赞：刘海把菜单栏图标藏了](https://apple.stackexchange.com/questions/444113/how-to-prevent-macbook-pro-notch-from-hiding-menu-bar-icons-from-the-right)、[R] [菜单栏塞不下更多图标](https://apple.stackexchange.com/questions/454979/how-can-i-fit-more-things-on-my-mac-menu-bar)、[B] [少数派：菜单栏被刘海挤掉，只能靠第三方 hack](https://sspai.com/post/104699) | Ice（开源）/ Bartender / Hidden Bar | 🟡 |
| S4 | **Spotlight ≠ 开始菜单** | Win 开始菜单是"程序列表 + 搜索"；Mac 的 Launchpad 是网格、Spotlight 是搜索，两个入口两套逻辑，Spotlight 还会混入文件/邮件/词典结果 | [R] [r/mac："Spotlight 真的能搜到东西"](https://www.reddit.com/r/mac/comments/18vczdo/)、[A] [Apple：用 Spotlight 查找](https://support.apple.com/guide/mac-help/find-what-you-need-with-spotlight-mchlp1008/27/mac/27) | Raycast / Alfred 基本重写了这一层 | 🟢（已被占据） |
| S5 | **通知中心 / 勿扰的开关位置** | Win 在任务栏右下角一键开"专注"；Mac 要拉通知中心再切，快捷键长期缺失 | [R] [Ask Different 20 赞：能不能像 iPhone 一样一键开关勿扰](https://apple.stackexchange.com/questions/368697/can-i-toggle-do-not-disturb-on-off-on-my-mac-as-easily-as-i-can-on-my-iphone)、[R] [26 赞：用命令行控制勿扰](https://apple.stackexchange.com/questions/145487/how-to-enable-disable-do-not-disturb-from-shell-on-mavericks) | Focus 模式 + 控制中心；可做快捷键/菜单栏开关 | 🟢 |
| S6 | **系统设置"搬过家"，找不到对应项** | Win 用户脑内是"控制面板 → 鼠标/显示/网络"；macOS Ventura 后 System Preferences 改名 System Settings 并整体重排，连老 Mac 用户都在找 | [A] [Apple：更改系统设置](https://support.apple.com/guide/mac-help/change-system-settings-mh15217/27/mac/27)、[R] [r/MacOS 迁移帖：设置项到处找不到](https://www.reddit.com/r/MacOS/comments/1dnbpk8/) | 设置内搜索；无"Windows 名词 → Mac 位置"的对照表 | 🟢 |

## 6. 其他高频摩擦

| # | 痛点（短标题） | 现象：Windows 习惯 vs Mac 行为 | 证据 | 现有解法 | 判断 |
|---|---|---|---|---|---|
| O1 | **没有剪贴板历史** | Win 有 Win+V 历史面板；macOS 长期无入口，Tahoe 才把剪贴板历史塞进 Spotlight（要先唤 Spotlight 再切一栏，两步） | [R] [r/mac："我怀念 Win+V"](https://www.reddit.com/r/mac/comments/1to0fsd/)、[R] [r/mac：为什么 macOS 没有 Win+V](https://www.reddit.com/r/mac/comments/1t448z8/)、[R] [同帖："Tahoe 内置了但很别扭"](https://www.reddit.com/r/mac/comments/1to0fsd/) | Maccy（开源）/ Paste / Raycast | 🟢（竞争激烈） |
| O2 | **"关机"与"合盖"的语义** | Win 用户习惯每天关机；Mac 是合盖休眠、长期不关，"睡眠/休眠/安全睡眠"的区别没有 UI 说明，担心"没关机会不会耗电/丢数据" | [R] [Ask Different：M1 上如何开启休眠](https://apple.stackexchange.com/questions/416108/how-to-enable-hibernation-on-m1-mac)、[B] [少数派：合盖即走是 Mac 的加分项](https://sspai.com/post/104699) | 系统默认即可；缺解释性引导 | 🔴（不该做） |
| O3 | **打印对话框"藏起来了"** | Win 一打开就有页码范围/双面/纸型；Mac 默认只显示打印机和份数，要点"显示详细信息"才展开，第一次打印的人会以为功能没了 | [A] [Apple：打印文稿](https://support.apple.com/guide/mac-help/print-documents-mh35838/27/mac/27) | 系统"显示详细信息" | 🔴（系统设计，改了很脆） |
| O4 | **截图后没有 Win 式标注流** | Win 是 Win+Shift+S 截完直接进 Snipping Tool 涂画；Mac 截完先落桌面，标注要点浮动缩略图进"标记" | [A] [Apple：截图与标记](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac)、[R] [r/MacOS：⇧⌘5 比 ⇧⌘4 好用](https://www.reddit.com/r/MacOS/comments/1no8y6g/) | 系统"标记" + 微信/QQ 截图 | 🟡 |
| O5 | **外接键盘的 Win 键行为不可预期** | 同一把键盘在 Win 上是 Win 键、在 Mac 上是 ⌘，但部分键盘固件把 Win 键发成别的键码，导致"换台机器快捷键全乱" | [R] [Ask Different 14 赞：Win 键没有自动映射](https://apple.stackexchange.com/questions/159723/mac-osx-not-automatically-remapping-windows-key-to-cmd)、[R] [按键盘分别配置修饰键](https://apple.stackexchange.com/questions/94903/how-can-i-remap-keys-on-an-external-keyboard-but-keep-the-default-layout-on-the) | 修饰键按键盘配置；Karabiner 可做设备级规则 | 🟢 |

## 7. Top 5 优先级建议

排序依据：**影响面（多少迁移用户会撞上）× 可解性（能否纯软件解决、权限是否可接受）× 竞品空白（现有工具是否已经做好）**。

| 排名 | 方向 | 影响面 | 可解性 | 竞品空白 | 为什么排这里 |
|---|---|---|---|---|---|
| **P1** | **一键「Windows 兼容模式」总控** | 极高 | 🟢 | **极大** | 36 条里唯一**没人做**的形态：现有工具都是单点（只改键、只改滚动、只改窗口），没有一个"我来自 Windows，请把键位/滚动/窗口/右键一次性调成我熟悉的样子"的开关 + 引导。它同时是 P2–P5 的容器和分发入口，技术上全是已具备的 AX / CGEventTap 能力。 |
| **P2** | **分设备滚动方向 + 指针加速** | 极高 | 🟢 | 中（LinearMouse / Scroll Reverser 已占） | 诉求最刚性：每天插拔鼠标就触发一次，且已用 `defaults` 证明系统层没有按设备能力。空白不大但**是获客入口**——必须做到"比 LinearMouse 更傻瓜"（插上鼠标自动识别、给出"触控板自然 + 鼠标传统"一键预设），否则用户会直接装 LinearMouse。 |
| **P3** | **Home/End/PgUp/PgDn/Delete 键位兼容** | 高 | 🟡 | 大 | "每天都在用、但所有人都忍着"的痛点，评论情绪最激烈（"我换机后最大的抱怨"），Ask Different 上同主题提问 590 赞，**实测位列全站票数第 8**（仅 7 题高于它）。Karabiner 能做但配置门槛极高（写 JSON），普通用户没有替代品。难点在**按 App/按控件区分**（文本框走 Cocoa key binding，列表走 AX），需逐 App 兜底。 |
| **P4** | **⌘Tab → 窗口级切换 + 最小化唤起** | 高 | 🟡 | 中（AltTab / Contexts 已占） | "找不到窗口"是中文社区最高频的抱怨主题（知乎整篇长文都在讲），且"最小化后 ⌘Tab 唤不回"是纯行为缺陷、不是偏好问题。需覆盖系统 ⌘Tab（自绘 HUD + AX），工程风险中等但体验差异极明显，适合做 demo。 |
| **P5** | **Finder 右键增强（剪切/新建文件/复制路径）** | 中高 | 🟢 | 中（工具分散） | F1/F2/F3 三个诉求高度同源，一个 Finder 扩展就能全包；现有方案是"超级右键""New File Menu"等多个小工具，没有一个把"Windows 右键菜单"整体搬过来。适合作为 P1 的模块，而非独立产品。 |

**不推荐作为核心**：NTFS 写入（🔴 需 root/内核扩展）、菜单栏随 App 变化（🔴 系统语义，改了更怪）、电源与打印（🔴 收益低风险高）、截图标注（🟡 微信/QQ 已覆盖）。

## 8. 已被现有工具很好解决（别重复造轮子）

| 领域 | 代表工具 | 结论 |
|---|---|---|
| 全局启动器 / 搜索 / 剪贴板 | **Raycast**、Alfred | S4、O1 已饱和；应把它当"宿主"集成，而不是正面对抗 |
| 键位重映射 | **Karabiner-Elements** | K1–K6 的底层能力全都有，但**配置门槛高、无引导**——这正是 P1/P3 的空间 |
| 分设备滚动/指针 | **LinearMouse**、Scroll Reverser、Mac Mouse Fix | M1/M2/M4/M6 已解决，我们只能做"更傻瓜的预设层" |
| 滚轮平滑 | **Mos** | M5 已解决，用户对"过度平滑"敏感，别碰 |
| 窗口管理 | **Magnet**、Rectangle、Raycast | W8 已饱和；W4/W5 的"最大化语义"仍没人做顺手 |
| 窗口切换 | **AltTab**、Contexts | W1/W2 已有解，但 UI 陈旧、收费——P4 的空间在"轻 + 中文友好" |
| 菜单栏收纳 | **Ice**（开源）、Bartender | S3 已解决，属 hack 层，别重复 |
| 剪贴板历史 | **Maccy**（开源） | O1 已饱和 |
| 卸载残留 | **AppCleaner**、Pearcleaner | F6 已解决 |

### 8.1 各竞品的"能力边界"到哪为止（2026-11-08 实地核对官网）

上表是"谁占了哪块地"，下表是**它们明确做不到什么**——这决定了我们的空隙在哪。全部基于各产品官网自述，未做脑补。

| 工具 | 它明确擅长 | 它明确**不**负责（=我们的机会） |
|---|---|---|
| **Karabiner-Elements** | 键盘事件级重映射、按设备/按 App 的复杂规则、修饰键改造 | 只吃键盘。**不碰滚动、不碰窗口、不碰 Finder**。且规则用 JSON 写，**没有"我来自 Windows"这类成品预设**，普通用户止步于安装 |
| **LinearMouse** | 按设备分别设置滚动方向/指针速度/加速；device profile 自动切换 | 只做指针与滚动。**不碰键位、不碰窗口、不碰文件操作**。定位是"给你细粒度旋钮"，不是"告诉迁移用户该旋钮到哪" |
| **Mac Mouse Fix** | 把普通鼠标做出触控板级手感（滚动、拖拽、按键映射），官网自述主打 "Make Your $10 Mouse Better Than an Apple Trackpad" | **纯鼠标体验层**，且叙事是"把你的鼠标变强"，完全不是"迁移"语境。键位与窗口不在射程 |
| **Mos** | 滚轮平滑与步进分离（M5） | **单一功能**，不涉及方向、键位、窗口 |
| **BetterTouchTool** | 触控板手势 + 鼠标 + 键盘 + 菜单栏 + Stream Deck，600+ 动作可串联，能力上限最高 | **样样强但样样要自己配**。官网叙事是"Make your Mac truly yours"（为你已有的习惯做定制），**默认假设用户已经知道自己想要什么**；迁移用户恰恰是"不知道自己该改什么"的那群人 |
| **Magnet / Rectangle** | 贴边分屏、快捷键平铺（W8） | 只解决"窗口摆哪"。**不碰绿灯全屏语义（W4）**，也不碰键位/滚动 |
| **Raycast** | 启动器、搜索、剪贴板、窗口管理、扩展生态 | 是**效率操作台**，不是迁移向导。它的扩展能拼出部分能力，但**没有一条"从 Windows 来，按这个顺序改"的路径** |
| **AltTab** | 窗口级 ⌘Tab 替换（W1/W2） | 单点替换系统切换器，**UI 陈旧、无中文引导**，不处理键位/滚动 |

**结论**：没有任何一个工具在做「**迁移态的编排**」。现有工具的共同假设是 *"用户已经会用 Mac，只是想要更细的控制"*；迁移用户的真实状态是 *"我不知道该改什么，也不知道 Mac 为什么这样设计"*。这个认知差就是 P1 的全部依据——**不是造新能力，而是把已有能力的正确组合一次性配好，并解释为什么**。

## 9. 结论：产品空隙在哪

1. **最大的空隙不是"某个功能没人做"，而是"没人把散落的单点方案串成一次迁移"**。现有工具都假设用户已经会用 Mac、只是想要更细的控制；迁移用户的真实状态是"我不知道该改什么"。P1 的总控 + 引导是唯一能同时吃到所有痛点流量的形态。
2. **可解性普遍偏高**：36 条里 19 条判 🟢，且都落在 Accessibility / CGEventTap / AX 这几个可获得的权限面上，不需要内核扩展、不需要 root。
3. **必须承认的边界**：NTFS、菜单栏语义、电源/打印属 🔴，写进 roadmap 会拖垮可信度；M1 若做成"第二个 LinearMouse"就是失败，必须做成"一次性迁移向导里的一步"。

## 附：采集局限（供复核）

- 知乎问答页（`zhihu.com/question/*`）与 Apple 支持社区中文版有登录/验证码墙，**正文与评论区未能逐条读取**，相关条目标 `[B]` 或仅引用标题；知乎专栏 `p/2072985238423204478` 与少数派 `post/104699` 为完整读取。
- Reddit 通过 `.rss` 端点抓取（含评论文本），部分帖子被限流未取到，已换用同主题等效帖子；所有 `reddit.com/r/.../comments/...` 链接均为真实帖子，可点开复核。
- 本机验证项：`com.apple.swipescrolldirection`（全局唯一）、`com.apple.AppleMultitouchTrackpad`（无方向键）、`com.apple.symbolichotkeys` 60/61（输入源切换）、`com.apple.keyboard.fnState`（未设置=媒体键）。
- 少数中文来源（如 F7）只有标题与摘要可读，正文因 403/登录墙未能核对，已在条目中降级为 `[B]`。
- 与同目录其他调研稿的关系：本文覆盖需求侧全量清单；`tech-feasibility.md` 覆盖实现侧，两者不重复。

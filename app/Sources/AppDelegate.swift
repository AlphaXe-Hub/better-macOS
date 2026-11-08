import AppKit
import ApplicationServices

// MARK: - 应用外壳

/// 把各模块接起来的地方。这里**只做编排**，不实现任何业务逻辑——
/// 业务都在 MenuInventory / KeyWatcher / ShortcutResolver / HUDController / Correction 里。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let tracker = FrontmostAppTracker()
    private let inventory = MenuInventory()
    private let keyWatcher = KeyWatcher()
    private let resolver = ShortcutResolver()
    private let hud = HUDController()
    private let registry = CorrectionRegistry()

    private var prefs: PreferencesWindow?
    private var browser: ShortcutBrowserWindow?
    private var guide: MigrationGuideWindow?
    private var permGuide: PermissionGuideWindow?
    private var lastSnapshot: MenuInventory.Snapshot?
    private var lastReadError: MenuInventory.Failure?
    private var hotKeyMonitor: Any?

    /// 调试入口：由 `main.swift` 按启动参数设置，仅开发期使用。
    enum DebugTarget { case guide, prefs, browser, permission }
    var debugOpenTarget: DebugTarget?
    /// 用整张 Windows 对照表构造一份「示例 App 快照」代替真实前台菜单
    /// （`--open-browser-demo`）。用途：前台 App 的菜单不足以命中映射时，
    /// 仍然能验证面板第二行的版式。
    var debugDemoBrowser = false
    /// 端到端自证期间冻结菜单快照：否则前台 App 轮询会把注入的合成快照顶掉，
    /// 「按键 → 动作名」这段断言就会随机失败。
    private var freezeSnapshot = false
    /// 非 nil 时，打开窗口后把视图离屏渲染成 PNG 再退出（用于无录屏权限时验证布局）。
    var debugRenderTo: String?
    /// 非 nil 时，把一张**带 Windows 对照**的吐司渲染成 PNG 再退出（`--render-toast`）。
    /// 吐司窗口 1.6 秒后自动消失，没有这个入口就无法留下版式证据。
    var debugRenderToastTo: String?
    private var debugRenderRetries = 0
    /// `--e2e-toast`：跑吐司的端到端自证（见文件末尾的 ToastE2ERunner）。
    var debugToastE2E = false

    // MARK: 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()

        // 前台 App 变化 → 重新绑定观察器
        tracker.onChange = { [weak self] app in
            guard let self else { return }
            self.rebind(to: app)
        }
        tracker.start()

        // 菜单动作触发 → 弹吐司
        keyWatcher.onKeyDown = { [weak self] stroke in
            self?.handleKey(stroke)
        }
        keyWatcher.start()

        // 修正项需要权限时，走统一的拖拽引导
        registry.onNeedPermission = { [weak self] in self?.openPermissionGuide() }

        // 恢复上次开着的修正项
        registry.restoreSaved()

        // 首次启动且未授权：主动引导一次，但不要反复打扰
        // （端到端自证期间不弹：那会多出几个窗口，污染「屏上有几张吐司」的断言）
        if !debugToastE2E,
           !Permissions.hasAccessibility && !UserDefaults.standard.bool(forKey: "perm.prompted") {
            UserDefaults.standard.set(true, forKey: "perm.prompted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.openGuide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.openPermissionGuide()
                }
            }
        }

        // 全局热键 ⌥⌘K 打开快捷键面板
        installHotKeyMonitor()
        startPermissionRecovery()

        // 端到端自证：合成按键 → 生产 handleKey → 吐司窗口 → Window Server 反查
        if debugToastE2E {
            runToastE2E()
            return
        }

        // 调试入口
        if let target = debugOpenTarget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                switch target {
                case .guide:   self.openGuide()
                case .prefs:   self.openPrefs()
                case .browser: self.openBrowser()
                case .permission: self.openPermissionGuide()
                }
                if let path = self.debugRenderTo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        // 真实快照的前几屏是 Apple 菜单（没有 Windows 对应），
                        // 滚到第一条命中的行，截图里才看得到第二行。
                        if case .some(.browser) = self.debugOpenTarget, !self.debugDemoBrowser {
                            self.browser?.scrollToFirstWindowsEquivalent()
                        }
                        self.renderOpenWindows(to: path)
                    }
                }
            }
        }

        // 吐司版式证据：不需要真实按键、不依赖前台 App，直接把带 Windows 第二行的
        // 吐司视图离屏渲染出来。走的是生产用的 ToastView，画成什么样就是运行时的样子。
        if let path = debugRenderToastTo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.renderToastSample(to: path)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        keyWatcher.stop()
        for c in registry.corrections where c.isOn { c.disable() }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusBarImage()
            // 模板图：系统按菜单栏明暗自动染成黑/白。少了这一行，
            // 深色菜单栏下白色图标会变成一块糊掉的方块。
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "快捷键面板…", action: #selector(openBrowser), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openPrefs), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 better-macOS", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    /// 菜单栏图标。优先用 bundle 里的 MenuBarIcon（由 app/tools/gen-icons.sh 生成），
    /// 缺失时退回系统符号——直接用 SF Symbol 会在 Dock 与菜单栏之间产生视觉断层，
    /// 所以它只是兜底，不是正常路径。
    private static func statusBarImage() -> NSImage? {
        // 不要改 size：@1x 是 13x18 pt，正好是菜单栏该有的尺寸。
        // 之前按宽高比重设 size，把 18pt 的画布放大成 22pt，图标会被菜单栏切掉。
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "better-macOS")
        fallback?.isTemplate = true
        return fallback
    }

    // MARK: 前台 App 绑定

    private func rebind(to app: FrontmostAppTracker.App?) {
        guard let app else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.inventory.snapshot(pid: app.pid, appName: app.name)
            DispatchQueue.main.async {
                // 端到端自证期间由测试注入合成快照；真实的前台 App 轮询会把它顶掉。
                guard !self.freezeSnapshot else { return }
                switch result {
                case .success(let snap):
                    self.lastSnapshot = snap
                    self.lastReadError = nil
                    NSLog("[better-macOS] %@: %d shortcuts", snap.appName, snap.withShortcuts.count)
                    self.diag("SNAPSHOT \(snap.appName) items=\(snap.items.count) withKeys=\(snap.withShortcuts.count)")
                case .failure(let err):
                    self.lastSnapshot = nil
                    self.lastReadError = err
                    NSLog("[better-macOS] read menu of %@ failed: %@", app.name, String(describing: err))
                    self.diag("SNAPSHOT-FAIL \(app.name): \(String(describing: err))")
                }
            }
        }
    }

    /// 决定「这次按键要不要弹吐司」的全部策略都在这里。
    ///
    /// 四条规则，按顺序：
    /// 1. **没按修饰键的一律不弹**——那是打字。每按一个字母弹一次是不可用的产品。
    /// 2. **单按修饰键本身不弹**——⌘、⇧ 单独按下不是动作。
    /// 3. **有修饰键但没绑定菜单的，弹一句「未绑定」**——
    ///    对迁移者来说「我按了但没反应」是最需要解释的状态，
    ///    而这正是 Windows 肌肉记忆落空的时刻。
    /// 4. **同一个组合被反复按**时，即使规则 3 的开关是关的，也解释一次
    ///    （`UnboundNudge`）。这是「查表失败不再静默」的落点：用户反复按同一个
    ///    组合却没反应，说明他正在困惑，此时沉默就是在让他以为工具坏了。
    func diag(_ msg: String) { Diag.log(msg) }

    /// 「未绑定」按键的计数，键是组合串（`⌃⌥J` 这种带修饰键、菜单里又没有的组合）。
    ///
    /// 只留最近按过的那几十个：一个长尾字典会一直涨，而这个表只服务于
    /// 「刚刚在反复按什么」。给个硬上限，省得为它写淘汰算法。
    private var unboundPresses: [String: UnboundNudge.Presses] = [:]
    private static let maxTrackedUnbound = 32

    private func handleKey(_ stroke: KeyStroke) {
        let hudEnabled = UserDefaults.standard.object(forKey: "hud.enabled") as? Bool ?? true
        guard hudEnabled else { return }

        // 规则 1：纯普通键 = 打字，不打扰
        guard !stroke.modifiers.isEmpty else { return }

        let resolution = resolver.resolve(stroke: stroke, in: lastSnapshot)
        let showUnknown = UserDefaults.standard.object(forKey: "hud.show-unknown") as? Bool ?? false

        // 只有「我们查得到菜单、但确实没绑定」才计数。`noSnapshot` 是我们的问题
        // 不是键的问题，拿它计数会得出「用户反复按了一个不存在的键」的错误结论。
        var repeated = false
        var nudgeLine = ""
        if resolution.miss == .notBound {
            let now = ProcessInfo.processInfo.systemUptime
            let presses = UnboundNudge.record(presses: unboundPresses[stroke.combo], now: now)
            unboundPresses[stroke.combo] = presses
            repeated = UnboundNudge.shouldExplain(presses)
            if unboundPresses.count > Self.maxTrackedUnbound {
                unboundPresses = Dictionary(uniqueKeysWithValues:
                    unboundPresses.sorted { $0.value.lastAt > $1.value.lastAt }
                        .prefix(Self.maxTrackedUnbound)
                        .map { ($0.key, $0.value) })
            }
            nudgeLine = "  · 未绑定计数：第 \(presses.count) 次，已解释 \(presses.explained) 次"
                + "（反复按才解释：\(UnboundNudge.threshold) 次 / 间隔 ≤ \(Int(UnboundNudge.idleGap))s）"
                + (repeated ? " → 这次开口" : " → 继续沉默")
        }

        diag("KEY \(stroke.combo)  snapshot=\(lastSnapshot?.appName ?? "NIL")(\(lastSnapshot?.items.count ?? 0)项)  action=\(resolution.action ?? "未绑定")  miss=\(String(describing: resolution.miss))")
        if !nudgeLine.isEmpty { diag(nudgeLine) }

        let content: ToastContent
        if let action = resolution.action {
            content = ToastContent(action: action,
                                   combo: stroke.combo,
                                   windowsEquivalent: WindowsEquivalents.lookup(combo: stroke.combo, action: action),
                                   sourceApp: resolution.appName)
        } else if let copy = resolution.unboundCopy,
                  UnboundPolicy.shouldToast(miss: resolution.miss,
                                            showUnknown: showUnknown,
                                            repeated: repeated) {
            content = ToastContent(action: copy.title,
                                   combo: stroke.combo,
                                   windowsEquivalent: nil,
                                   sourceApp: resolution.appName,
                                   note: copy.note)
            // 解释过一次就记账，同一个组合不会无限重复解释。
            if resolution.miss == .notBound, let p = unboundPresses[stroke.combo] {
                unboundPresses[stroke.combo] = UnboundNudge.didExplain(p)
            }
        } else {
            diag("  → 未绑定且当前策略下不弹")
            return   // 规则 3 默认关闭：不解释未绑定键，避免噪音
        }
        hud.show(content)
        diag("  → 吐司已发出: \(content.action)")
    }

    // 未绑定时的弹不弹策略在 UnboundPolicy（KeyWatcher.swift），那里能被单测直接断言。

    // MARK: 授权后自愈

    /// 用户很可能在 App 已经运行时才去授权。
    /// 那一刻 `lastSnapshot` 是失败的，而且不会自己重试——所以必须主动轮询。
    private var permissionTimer: Timer?
    private var sawPermission = Permissions.hasAccessibility

    private func startPermissionRecovery() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Permissions.hasAccessibility
            if now && !self.sawPermission {
                self.sawPermission = true
                NSLog("[better-macOS] permission became available, re-reading menus")
                // 重新读一次当前前台 App；之前失败的快照要作废
                self.lastReadError = nil
                self.tracker.refresh()
                if self.lastSnapshot == nil { self.rebind(to: self.tracker.current) }
                // 权限生效前装的监听器是无效的（能装但零投递），必须重装
                self.keyWatcher.start()
                self.diag("permission granted → key watcher reinstalled")
            } else if !now && self.sawPermission {
                self.sawPermission = false
                NSLog("[better-macOS] permission lost (ad-hoc 重编译会导致)")
                self.lastSnapshot = nil
            }
        }
    }

    // MARK: 迁移清单

    @objc private func openGuide() {
        if guide == nil {
            let w = MigrationGuideWindow(registry: registry)
            w.onRequestPermission = { [weak self] in self?.openPermissionGuide() }
            guide = w
        }
        presentWindow(guide)
    }

    /// accessory App（LSUIElement）没有 Dock 图标，`activate` 不总能真正把窗口带到前台。
    /// 三步都要做：激活、makeKey、orderFrontRegardless。
    private func presentWindow(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: 快捷键面板

    @objc private func openBrowser() {
        // 调试：用整张对照表演一个「示例 App」，直接验证面板第二行版式。
        if debugDemoBrowser {
            let snap = MenuInventory.Snapshot(appName: "Windows 键位对照（示例）",
                                              pid: 0,
                                              items: WindowsEquivalents.demoItems())
            let w = ShortcutBrowserWindow(snapshot: snap) { _ in }
            browser = w
            NSApp.activate(ignoringOtherApps: true)
            w.orderFrontRegardless()
            w.focusSearch()
            return
        }
        // 现场重读一次：用户可能刚授权、或刚切 App，缓存的快照可能是旧的/失败的
        if Permissions.hasAccessibility, let app = tracker.current,
           lastSnapshot == nil || lastSnapshot?.pid != app.pid {
            switch inventory.snapshot(pid: app.pid, appName: app.name) {
            case .success(let snap):
                lastSnapshot = snap
                lastReadError = nil
            case .failure(let err):
                lastReadError = err
            }
        }
        guard let snapshot = lastSnapshot else {
            let a = NSAlert()
            a.messageText = "读不到当前 App 的菜单"
            switch lastReadError {
            case .noPermission:
                a.informativeText = "需要先在「系统设置 → 隐私与安全性 → 辅助功能」里授权 better-macOS。"
                a.addButton(withTitle: "去授权")
                a.addButton(withTitle: "取消")
                if a.runModal() == .alertFirstButtonReturn {
                    self.openPermissionGuide()
                }
            case .cannotComplete:
                a.informativeText = "这个 App 没有及时响应菜单查询，或者权限尚未生效。\n如果刚授权完，请先退出并重新启动 better-macOS。"
                a.addButton(withTitle: "好")
                a.runModal()
            case .noMenuBar:
                a.messageText = "这个 App 没有菜单栏"
                a.informativeText = "「\(tracker.current?.name ?? "当前 App")」是后台进程或菜单栏小组件，没有可供读取的菜单。\n切到 Safari、Chrome、Finder 这类正常 App 再试。"
                a.addButton(withTitle: "好")
                a.runModal()
            case .appGone:
                a.informativeText = "这个 App 已经不在了，切到别的 App 再试。"
                a.addButton(withTitle: "好")
                a.runModal()
            default:
                a.informativeText = "未知原因。如果刚授予权限，请先重启 better-macOS。"
                a.addButton(withTitle: "好")
                a.runModal()
            }
            return
        }
        browser?.orderOut(nil)
        let w = ShortcutBrowserWindow(snapshot: snapshot) { item in
            // v2：点击执行菜单动作。v1 先用 AX 的 AXPress。
            NSLog("[better-macOS] fire: %@ (%@)", item.title, item.combo)
        }
        browser = w
        NSApp.activate(ignoringOtherApps: true)
        w.orderFrontRegardless()
        w.focusSearch()
    }

    private func installHotKeyMonitor() {
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 40 /* k */ && mods == [.command, .option] {
                self.openBrowser()
                return nil
            }
            return event
        }
    }

    // MARK: 设置

    /// 打开的权限引导（拖拽式）。已有实例就复用。
    func openPermissionGuide() {
        if permGuide == nil {
            let w = PermissionGuideWindow()
            w.onGranted = { [weak self] in
                guard let self else { return }
                // 授权后需要重建前台菜单快照：之前失败过的那次不会自己重试。
                self.tracker.refresh()
            }
            permGuide = w
        }
        permGuide?.present()
    }

    @objc private func openPrefs() {
        if prefs == nil {
            let w = PreferencesWindow(registry: registry)
            w.onRequestPermission = { [weak self] in self?.openPermissionGuide() }
            prefs = w
        }
        presentWindow(prefs)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 把一个窗口的视图树离屏渲染成 PNG。
    /// 绕过屏幕录制权限：读的是自己的视图缓存，不是显示器内容。
    func renderOpenWindows(to path: String) {
        let windows = [permGuide as NSWindow?, guide, prefs, browser].compactMap { $0 }
        guard let w = windows.first else {
            NSLog("[better-macOS] render: no window"); NSApp.terminate(nil); return
        }
        // 用户尚未把窗口调出来时（例如窗口是异步打开的），给布局一点时间。
        w.contentView?.layoutSubtreeIfNeeded()
        w.layoutIfNeeded()
        guard let root = w.contentView else {
            NSLog("[better-macOS] render: no contentView"); NSApp.terminate(nil); return
        }
        // 内容是 NSScrollView 时渲染**整篇文档**而不是可视区：设置页随着「系统级
        // 快捷键清单」变长之后，只拍可视区等于只验证了第一屏，下半部分永远是盲区
        // （加清单这次就是这样漏掉的）。滚动视图自己的 bounds 不随内容增长。
        let view: NSView = (root as? NSScrollView)?.documentView ?? root
        let size = view.bounds.size
        guard size.width > 10, size.height > 10 else {
            guard debugRenderRetries < 3 else {
                NSLog("[better-macOS] render: giving up (view never laid out)")
                NSApp.terminate(nil); return
            }
            debugRenderRetries += 1
            NSLog("[better-macOS] render: view too small (%.0fx%.0f), retry %d/3",
                  size.width, size.height, debugRenderRetries)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.renderOpenWindows(to: path) }
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[better-macOS] render: no rep"); NSApp.terminate(nil); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("[better-macOS] rendered %@ -> %@ (%.0fx%.0f)", w.title, path, size.width, size.height)
        }
        NSApp.terminate(nil)
    }

    /// 把一张带 Windows 对照的吐司离屏渲染成 PNG。
    /// 用真实的 ToastView + fittingSize，所以同时证明「第二行画得出来」和「尺寸把它算进去了」。
    func renderToastSample(to path: String) {
        // 第二类文案（issue #11 第 4 条）：系统级快捷键。带上它，`--render-toast`
        // 才能留下「我们确实把系统键说清楚了」的版式证据，而不只是一句代码注释。
        let reserved = SystemShortcuts.lookup(combo: "fn⌃←")
        let content = ToastContent(action: reserved?.name ?? "平铺到左半屏",
                                   combo: "fn⌃←",
                                   windowsEquivalent: nil,
                                   sourceApp: "示例",
                                   note: "macOS 系统快捷键 —— 由系统直接处理，不在 App 菜单里")
        let view = ToastView(content: content)
        // 顺序必须和 ToastWindow.init 一致：**先取 fittingSize 再设 frame**。
        // 先 layout 再量会缓存一份零尺寸的布局，长标题会被截断（我踩过）。
        var size = view.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 200, height: 70) }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[better-macOS] render-toast: no rep"); NSApp.terminate(nil); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("[better-macOS] rendered toast -> %@ (%.0fx%.0f)", path, size.width, size.height)
        }
        NSApp.terminate(nil)
    }

    // MARK: 首次引导

}

// MARK: - 吐司端到端自证（app/e2e.sh）

/// `--e2e-toast` 的实现：**真的合成一次按键**，走完整条
/// `KeyWatcher → handleKey → ShortcutResolver → HUDController.show() → NSPanel`
/// 链路，然后**从 Window Server 反查**那张窗口在不在屏幕上。
///
/// 为什么必须以 Window Server 为准：这个 App 最危险的失败模式是
/// 「日志说吐司已发出，屏幕上一片空白」——代码走到了 `show()`，
/// 但窗口被 AppKit 的隐式行为藏掉了（历史 bug 7e9b9a5：`NSPanel.hidesOnDeactivate`
/// 默认 true，而 accessory App 永远不会 active）。**实测那种状态下
/// `NSWindow.isVisible` 仍然是 true，只有 Window Server 的 onscreen 列表是空的。**
/// 「调用过 orderFrontRegardless」和「窗口真的在屏幕上」是两件事，
/// 这里断言的永远是后者。
extension AppDelegate {

    func runToastE2E() {
        let runner = ToastE2ERunner(
            hud: hud,
            watcher: keyWatcher,
            makeSnapshot: { Self.e2eSnapshot() },
            adoptSnapshot: { [weak self] snap in self?.lastSnapshot = snap },
            deliverStroke: { [weak self] stroke in self?.handleKey(stroke) },
            freezeBackground: { [weak self] in
                guard let self else { return }
                self.freezeSnapshot = true      // 别让前台 App 轮询顶掉合成快照
                self.tracker.stop()
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            })
        runner.start()
    }

    /// 固定的合成菜单：断言的是「按键 → 动作名 → 窗口」这段链路，
    /// 不能依赖跑测试时前台恰好是哪个 App。键位故意选四修饰键 + 7/8：
    /// 即使合成事件真的漏给前台 App，也不可能意外触发真实菜单动作。
    private static func e2eSnapshot() -> MenuInventory.Snapshot {
        let mods: ShortcutModifiers = [.command, .shift, .option, .control]
        func item(_ title: String, _ key: String) -> ShortcutItem {
            ShortcutItem(title: title, menuGroup: "E2E", key: key, modifiers: mods, enabled: true)
        }
        return MenuInventory.Snapshot(
            appName: "E2E 合成菜单",
            pid: ProcessInfo.processInfo.processIdentifier,
            items: [
                item(ToastE2ERunner.firstAction, ToastE2ERunner.firstKey),
                item(ToastE2ERunner.secondAction, ToastE2ERunner.secondKey),
                item(ToastE2ERunner.lifeAction, ToastE2ERunner.lifeKey),
            ])
    }
}

/// 自证执行器。单独成类，是为了让 `AppDelegate` 的编排一行都不变——
/// #4 的 worker 还要改 `handleKey`，这里刻意只**调用**它，不碰它。
private final class ToastE2ERunner {

    // 键位故意选四修饰键 + 数字：即使合成事件真的漏给前台 App，
    // 也不可能意外触发任何真实菜单动作。
    static let mods: ShortcutModifiers = [.command, .shift, .option, .control]
    static let firstKey = "7"
    static let secondKey = "8"
    static let lifeKey = "9"
    static let firstAction = "端到端测试动作"
    static let secondAction = "端到端堆叠动作"
    static let lifeAction = "端到端存活动作"
    /// 合成菜单里**没有**这一项 → 用来验「未绑定不弹」
    static let unboundKey = "0"

    private let hud: HUDController
    private let watcher: KeyWatcher
    private let makeSnapshot: () -> MenuInventory.Snapshot
    private let adoptSnapshot: (MenuInventory.Snapshot) -> Void
    private let deliverStroke: (KeyStroke) -> Void
    private let freezeBackground: () -> Void

    private let t0 = Date()
    private var pass = 0
    private var fail = 0
    private var skipped = 0
    private var failedNames: [String] = []

    private var seenStrokes: [KeyStroke] = []
    private var logOffset: UInt64 = 0
    /// 自证会临时改动这两个开关；必须原样还回去，否则会改掉用户真实的吐司行为。
    private static let touchedDefaults = ["hud.enabled", "hud.show-unknown"]
    private var savedDefaults: [String: Any] = [:]

    init(hud: HUDController,
         watcher: KeyWatcher,
         makeSnapshot: @escaping () -> MenuInventory.Snapshot,
         adoptSnapshot: @escaping (MenuInventory.Snapshot) -> Void,
         deliverStroke: @escaping (KeyStroke) -> Void,
         freezeBackground: @escaping () -> Void) {
        self.hud = hud
        self.watcher = watcher
        self.makeSnapshot = makeSnapshot
        self.adoptSnapshot = adoptSnapshot
        self.deliverStroke = deliverStroke
        self.freezeBackground = freezeBackground
    }

    // MARK: 主流程

    func start() {
        print("══════════════════════════════════════════════════════════════")
        print(" better-macOS 吐司端到端自证  (--e2e-toast)")
        print(" 断言对象是「Window Server 的屏幕上真的有一张吐司」，")
        print(" 不是「代码调用过 show()」——这两件事历史上并不等价（commit 7e9b9a5）。")
        print("══════════════════════════════════════════════════════════════")

        environment()
        logOffset = currentLogSize()
        snapshotDefaults()
        // 保证链路本身可跑通（用户可能关掉了吐司）；结束时还原
        UserDefaults.standard.set(true, forKey: "hud.enabled")
        UserDefaults.standard.set(false, forKey: "hud.show-unknown")
        freezeBackground()

        // 给启动时在途的真实快照一点时间落地，再冻结并换成合成快照
        after(0.25) {
            self.adoptSnapshot(self.makeSnapshot())
            self.observeStrokes()
            self.scenarioSingleToast()
        }
    }

    private func environment() {
        check("ENV.ACCESSIBILITY", AXIsProcessTrusted(),
              "AXIsProcessTrusted()=\(AXIsProcessTrusted())　全局按键监听需要它")
        check("ENV.EVENT_POST_ACCESS", CGPreflightPostEventAccess(),
              "CGPreflightPostEventAccess()=\(CGPreflightPostEventAccess())　合成按键需要它")
        check("ENV.LOG_WRITABLE", logWritable(), "Diag 日志可写：\(Diag.url.path)")
    }

    /// 把监听器的回调换成「记录 + 转给生产的 handleKey」。
    /// 仍然调用生产的 handleKey，绝不复制它的过滤逻辑——
    /// 否则这段自证会在 handleKey 改坏时依然变绿（#4 正要改它）。
    private func observeStrokes() {
        watcher.onKeyDown = { [weak self] stroke in
            guard let self else { return }
            self.seenStrokes.append(stroke)
            self.deliverStroke(stroke)
        }
    }

    // MARK: 场景 1：按一次键 → 屏幕上出现一张吐司

    private func scenarioSingleToast() {
        postSynthetic(keyCode: Self.keyCode(Self.firstKey))
        let receivedKey = { self.seenStrokes.contains { $0.key == Self.firstKey && $0.modifiers == Self.mods } }

        poll(timeout: 2.5, { self.hud.activeToasts.count >= 1 }) { arrived in
            guard arrived, let toast = self.hud.activeToasts.last else {
                let received = receivedKey()
                self.check("KEY.RECEIVED", received,
                           received
                             ? "全局监听器收到合成按键 \(Self.mods.symbols + Self.firstKey)"
                             : "2.5s 内全局监听器收到 0 次投递（合成按键没进得来）")
                self.check("KEY.RESOLVED", false,
                           received ? "按键已送达但没弹窗 = 真 bug" : "没有按键，链路未启动")

                // 环境挡住合成按键时，窗口这一段仍然值得断言：
                // 直接走生产 handleKey，让「吐司窗口真的在屏上」照样被验证。
                print("      ↳ 回退：直接调用生产的 handleKey，继续验证窗口这一段")
                self.deliverStroke(KeyStroke(key: Self.firstKey, modifiers: Self.mods))
                self.poll(timeout: 1.5, { self.hud.activeToasts.count >= 1 }) { ok in
                    self.check("TOAST.CREATED_BY_FALLBACK", ok,
                               "直接调用 handleKey 后生成了吐司=\(ok)")
                    self.afterFirstToast()
                }
                return
            }

            self.check("KEY.RECEIVED", receivedKey(),
                       "全局监听器收到合成按键 \(Self.mods.symbols + Self.firstKey)（真实 CGEvent 投递）")
            self.check("KEY.RESOLVED", toast.content.action == Self.firstAction,
                       "按键 → 动作名 = 「\(toast.content.action)」")
            self.afterFirstToast()
        }
    }

    private func afterFirstToast() {
        after(0.35) {   // 等淡入动画（0.22s）+ Window Server 一帧
            guard let toast = self.hud.activeToasts.last else {
                self.check("HUD.EXISTS", false, "屏幕上没有吐司窗口可供断言")
                return self.finish()
            }
            self.verifyWindowFacts(toast)
            self.scenarioStack()
        }
    }

    // MARK: 场景 2：连续触发 → 堆叠，且新的在上

    private func scenarioStack() {
        postSynthetic(keyCode: Self.keyCode(Self.secondKey))
        poll(timeout: 2.5, { self.hud.activeToasts.count >= 2 }) { two in
            guard two else {
                self.check("STACK.COUNT", false,
                           "连续触发没有堆叠：期望 2 张，实得 \(self.hud.activeToasts.count) 张")
                return self.after(0.4) { self.scenarioLifetime() }
            }
            self.check("STACK.COUNT", true, "连续触发后屏上有 2 张")
            self.after(0.35) {
                self.verifyStack()
                self.scenarioLifetime()
            }
        }
    }

    private func verifyStack() {
        let wins = hud.activeToasts
        guard wins.count == 2, let older = wins.first, let newer = wins.last else {
            check("STACK.NEW_ON_TOP", false, "堆叠数量异常（\(wins.count) 张），无法断言顺序")
            return
        }
        check("STACK.ORDER_OF_CONTENT",
              older.content.action == Self.firstAction && newer.content.action == Self.secondAction,
              "先「\(older.content.action)」后「\(newer.content.action)」")

        // 「新的在上」在 AppKit 里就是 y 更大（原点在左下）
        check("STACK.NEW_ON_TOP", newer.frame.minY > older.frame.minY,
              "新 minY=\(newer.frame.minY) > 旧 minY=\(older.frame.minY)")

        // 间距量「两窗相对的那条边」，不假设谁在上面——
        // 否则顺序错时这条会跟着一起红，把「顺序」和「间距」两个失败混成一个。
        let (lowerWin, upperWin) = older.frame.minY < newer.frame.minY ? (older, newer) : (newer, older)
        let clearance = upperWin.frame.minY - lowerWin.frame.maxY
        check("STACK.GAP", abs(clearance - 8) < 0.5,
              "两窗间隙=\(clearance)　期望 8（旧 maxY=\(older.frame.maxY) 新 minY=\(newer.frame.minY)）")

        let vis = NSScreen.main?.visibleFrame ?? .zero
        check("STACK.CENTERED_X",
              abs(newer.frame.midX - older.frame.midX) < 0.5 && abs(newer.frame.midX - vis.midX) < 0.5,
              "新 midX=\(newer.frame.midX)　旧 midX=\(older.frame.midX)　屏幕 midX=\(vis.midX)")

        check("STACK.BOTH_ON_SCREEN", wins.allSatisfy { WindowServer.onScreenInfo(for: $0) != nil },
              "两张都在 Window Server onscreen 列表里")
    }

    // MARK: 场景 3：生命周期（1.6s 存活 → 淡出 → orderOut → 离开 Window Server）

    /// 单独开一张新吐司来计时：堆叠场景里的第一张已经跑掉一部分寿命，
    /// 拿它来断言「1.15s 时仍在」会随调度抖动而假红——**计时必须从它自己的
    /// 出现时刻算起**。
    private func scenarioLifetime() {
        let before = hud.activeToasts.count
        postSynthetic(keyCode: Self.keyCode(Self.lifeKey))

        poll(timeout: 2.5, { self.hud.activeToasts.count == before + 1 }) { appeared in
            guard appeared, let toast = self.hud.activeToasts.last else {
                self.check("LIFETIME.CREATED", false,
                           "计时用的吐司没有出现（当前 \(self.hud.activeToasts.count) 张）")
                return self.after(3.0) { self.negativeCases() }
            }
            let shownAt = Date()
            self.check("LIFETIME.CREATED", toast.content.action == Self.lifeAction,
                       "新吐司已出现：「\(toast.content.action)」")

            // 1.15s 时（距它自己出现）应当完全不动
            self.after(1.15) {
                let managed = self.hud.activeToasts.contains { $0 === toast }
                let onScreen = WindowServer.onScreenInfo(for: toast) != nil
                let ok = managed && onScreen && toast.alphaValue > 0.99
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(shownAt))
                var detail = "存活期内一直可见：alpha=\(String(format: "%.3f", toast.alphaValue)) " +
                             "onScreen=\(onScreen) managed=\(managed)"
                if !ok {
                    let why = !managed ? "已从管理列表移除"
                            : !onScreen ? "不在 Window Server 的 onscreen 列表里（窗口被藏了）"
                            : "alpha 已掉到 \(String(format: "%.3f", toast.alphaValue))"
                    detail = "存活期内提前消失（\(why)）：alpha=\(String(format: "%.3f", toast.alphaValue)) " +
                             "onScreen=\(onScreen) managed=\(managed)"
                }
                self.check("LIFETIME.HOLDS", ok, "\(elapsed) 时 \(detail)")

                // 1.6s 起开始淡出，0.35s 后 orderOut
                self.poll(timeout: 2.0, { WindowServer.onScreenInfo(for: toast) == nil }) { gone in
                    self.check("LIFETIME.FADE_AND_ORDER_OUT", gone,
                               String(format: "%.2fs 时已淡出并离开 Window Server（isVisible=%@ alpha=%.3f）",
                                      Date().timeIntervalSince(shownAt), "\(toast.isVisible)", toast.alphaValue))
                    self.poll(timeout: 2.5, { self.hud.activeToasts.isEmpty }) { empty in
                        self.check("LIFETIME.ALL_CLEARED", empty,
                                   "所有吐司最终都退出管理列表（剩 \(self.hud.activeToasts.count) 张）")
                        self.negativeCases()
                    }
                }
            }
        }
    }

    // MARK: 场景 4：过滤规则（「不打扰」承诺的看门狗）

    /// 这里**直接调用 handleKey**（不合成按键），否则会真的往当前编辑器里打字。
    private func negativeCases() {
        check("FILTER.START_CLEAN", hud.activeToasts.isEmpty,
              "负例开始前屏上没有吐司（当前 \(hud.activeToasts.count) 张）")

        deliverStroke(KeyStroke(key: "A", modifiers: []))          // 规则 1：纯字母 = 打字
        check("FILTER.TYPING_NO_TOAST", hud.activeToasts.isEmpty,
              "无修饰键的 A 不弹（当前 \(hud.activeToasts.count) 张）")

        deliverStroke(KeyStroke(key: Self.unboundKey, modifiers: Self.mods))  // 规则 3：未绑定
        check("FILTER.UNBOUND_NO_TOAST", hud.activeToasts.isEmpty,
              "未绑定且 hud.show-unknown=false 时不弹（当前 \(hud.activeToasts.count) 张）")

        // 轮到「未绑定但 show-unknown=true」时应弹一句解释
        UserDefaults.standard.set(true, forKey: "hud.show-unknown")
        deliverStroke(KeyStroke(key: Self.unboundKey, modifiers: Self.mods))
        poll(timeout: 1.0, { !self.hud.activeToasts.isEmpty }) { explained in
            self.check("FILTER.UNBOUND_EXPLAINS_WHEN_ENABLED", explained,
                       "hud.show-unknown=true 时对未绑定键给出解释（当前 \(self.hud.activeToasts.count) 张）")
            self.after(2.4) { self.verifyLogEvidence() }
        }
    }

    // MARK: 场景 5：日志证据（issue 缺的就是这一半）

    /// 日志与窗口**同时**被验证，日志才有资格当证据。
    private func verifyLogEvidence() {
        guard logWritable() else {
            skip("DIAG.LOG_LINE", "\(Diag.url.path) 不可写，本环境无法验证日志")
            return finish()
        }
        let tail = readLogTail()
        check("DIAG.LOG_KEY_LINE", tail.contains("KEY \(Self.mods.symbols + Self.firstKey)"),
              "日志里出现「KEY \(Self.mods.symbols + Self.firstKey)」（按键那一段）")
        check("DIAG.LOG_LINE", tail.contains("→ 吐司已发出: \(Self.firstAction)"),
              "日志里出现「→ 吐司已发出: \(Self.firstAction)」（吐司已发出那一段）")
        finish()
    }

    // MARK: 工具

    /// Carbon 虚拟键码：7→26, 8→28, 9→25, 0→29
    private static func keyCode(_ key: String) -> CGKeyCode {
        switch key {
        case "7": return 26
        case "8": return 28
        case "9": return 25
        default:  return 29
        }
    }

    /// 合成一次真实的系统级按键（HID tap 投递，走的是和用户按键同一条路径）。
    private func postSynthetic(keyCode: CGKeyCode) {
        guard CGPreflightPostEventAccess() else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    private func poll(timeout: TimeInterval,
                      _ condition: @escaping () -> Bool,
                      then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if condition() { then(true); return }
            if Date() >= deadline { then(false); return }
            after(0.05, tick)
        }
        tick()
    }

    private func snapshotDefaults() {
        for key in Self.touchedDefaults {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key) ?? NSNull()
        }
    }

    private func restoreDefaults() {
        for key in Self.touchedDefaults {
            if savedDefaults[key] is NSNull {
                UserDefaults.standard.removeObject(forKey: key)
            } else if let v = savedDefaults[key] {
                UserDefaults.standard.set(v, forKey: key)
            }
        }
        UserDefaults.standard.synchronize()
    }

    private func currentLogSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Diag.url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func logWritable() -> Bool {
        guard let fh = try? FileHandle(forWritingTo: Diag.url) else { return false }
        try? fh.close()
        return true
    }

    /// 注意：**必须**用 onlyReading 打开。`FileHandle(forWritingTo:)` 拿到的是
    /// 只写句柄，读会失败并返回空——那样断言会以「日志里没有」的形式假红。
    private func readLogTail() -> String {
        let size = currentLogSize()
        guard size > logOffset, let fh = try? FileHandle(forReadingFrom: Diag.url) else { return "" }
        defer { try? fh.close() }
        let length = min(size - logOffset, 512 * 1024)
        try? fh.seek(toOffset: size - length)
        guard let data = try? fh.read(upToCount: Int(length)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fmt(_ r: NSRect) -> String {
        String(format: "(%.1f, %.1f, %.1fx%.1f)", r.origin.x, r.origin.y, r.width, r.height)
    }
    private func fmt(_ s: NSSize) -> String { String(format: "%.1fx%.1f", s.width, s.height) }

    // MARK: 断言

    private func verifyWindowFacts(_ toast: ToastWindow) {
        check("HUD.WINDOW_NUMBER", toast.windowNumber != 0,
              "windowNumber=\(toast.windowNumber)　0 表示没进 Window Server")

        // 历史 bug 的直接看门狗。注意 hidesOnDeactivate=true 时 HUD.IS_VISIBLE
        // 仍然是 true，只有 HUD.ON_SCREEN 会红——这两条一起看才说明「为什么不可见」。
        check("HUD.HIDES_ON_DEACTIVATE", toast.hidesOnDeactivate == false,
              "hidesOnDeactivate=\(toast.hidesOnDeactivate)　true 会让 accessory App 的窗口永不显示")

        check("HUD.IS_VISIBLE", toast.isVisible, "isVisible=\(toast.isVisible)")

        // 核心断言：Window Server 认不认它
        if let ws = WindowServer.onScreenInfo(for: toast) {
            check("HUD.ON_SCREEN", true, "Window Server onscreen 列表里有 windowNumber=\(toast.windowNumber)")
            check("HUD.WS_ALPHA", ws.alpha > 0.99, "Window Server alpha=\(ws.alpha)")
            check("HUD.WS_LEVEL", ws.layer == Int(NSWindow.Level.statusBar.rawValue),
                  "Window Server layer=\(ws.layer)　期望 \(Int(NSWindow.Level.statusBar.rawValue))（statusBar）")
            check("HUD.WS_SIZE",
                  abs(ws.size.width - toast.frame.width) < 1.5
                    && abs(ws.size.height - toast.frame.height) < 1.5,
                  "WS size=\(fmt(ws.size))　NSWindow frame=\(fmt(toast.frame.size))")
        } else {
            check("HUD.ON_SCREEN", false,
                  "Window Server 的 onscreen 列表里**没有** windowNumber=\(toast.windowNumber)　" +
                  "这就是历史上「日志说发了、屏幕上没有」的那种状态")
        }

        check("HUD.FRAME", toast.frame.width >= 120 && toast.frame.height > 0,
              "frame=\(fmt(toast.frame))")
        check("HUD.ALPHA", toast.alphaValue > 0.99, "alphaValue=\(toast.alphaValue)")

        let vis = NSScreen.main?.visibleFrame ?? .zero
        check("HUD.IN_VISIBLE_FRAME", vis.contains(toast.frame),
              "frame=\(fmt(toast.frame))　visibleFrame=\(fmt(vis))")

        check("HUD.LAYER", toast.contentView?.layer != nil,
              "contentView 已挂 layer=\(toast.contentView?.layer != nil)")

        // 空壳窗口也能让上面全绿，所以还要验「卡片上的字就是这次解析出的动作名」
        let texts = toast.displayedTexts
        check("HUD.CONTENT",
              texts.contains(Self.firstAction) && texts.contains(Self.mods.symbols + Self.firstKey),
              "视图里真实画出的文字=\(texts)　期望含「\(Self.firstAction)」与「\(Self.mods.symbols + Self.firstKey)」")

        check("HUD.NO_FOCUS_STEAL",
              toast.canBecomeKey == false && toast.isKeyWindow == false && toast.ignoresMouseEvents,
              "canBecomeKey=\(toast.canBecomeKey) isKeyWindow=\(toast.isKeyWindow) " +
              "ignoresMouseEvents=\(toast.ignoresMouseEvents)")
    }

    @discardableResult
    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        let d = detail()
        let stamp = String(format: "%5.2fs", Date().timeIntervalSince(t0))
        if ok {
            pass += 1
            print("PASS  [\(stamp)] \(name)\(d.isEmpty ? "" : "  —  \(d)")")
        } else {
            fail += 1
            failedNames.append(name)
            print("FAIL  [\(stamp)] \(name)\(d.isEmpty ? "" : "  —  \(d)")")
        }
        fflush(stdout)
        return ok
    }

    private func skip(_ name: String, _ why: String) {
        skipped += 1
        let stamp = String(format: "%5.2fs", Date().timeIntervalSince(t0))
        print("SKIP  [\(stamp)] \(name)  —  \(why)")
        fflush(stdout)
    }

    private func finish() {
        restoreDefaults()
        print("──────────────────────────────────────────────────────────────")
        if fail == 0 {
            print("结果：\(pass) 项 PASS" + (skipped > 0 ? "，\(skipped) 项 SKIP" : "")
                  + " —— 吐司端到端可见，链路自证通过")
        } else {
            print("结果：\(pass) 项 PASS / \(fail) 项 FAIL —— \(failedNames.joined(separator: ", "))")
        }
        print("──────────────────────────────────────────────────────────────")
        fflush(stdout)
        exit(fail == 0 ? 0 : 1)
    }
}

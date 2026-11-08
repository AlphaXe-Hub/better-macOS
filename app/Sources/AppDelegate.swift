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
    private var lastSnapshot: MenuInventory.Snapshot?
    private var lastReadError: MenuInventory.Failure?
    private var hotKeyMonitor: Any?

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

        // 恢复上次开着的修正项
        registry.restoreSaved()

        // 首次启动且未授权：主动引导一次，但不要反复打扰
        if !Permissions.hasAccessibility && !UserDefaults.standard.bool(forKey: "perm.prompted") {
            UserDefaults.standard.set(true, forKey: "perm.prompted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.showFirstRunGuidance()
            }
        }

        // 全局热键 ⌥⌘K 打开快捷键面板
        installHotKeyMonitor()
    }

    func applicationWillTerminate(_ n: Notification) {
        keyWatcher.stop()
        for c in registry.corrections where c.isOn { c.disable() }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "better-macOS")
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

    // MARK: 前台 App 绑定

    private func rebind(to app: FrontmostAppTracker.App?) {
        guard let app else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.inventory.snapshot(pid: app.pid, appName: app.name)
            DispatchQueue.main.async {
                switch result {
                case .success(let snap):
                    self.lastSnapshot = snap
                    self.lastReadError = nil
                    NSLog("[better-macOS] %@: %d shortcuts", snap.appName, snap.withShortcuts.count)
                case .failure(let err):
                    self.lastSnapshot = nil
                    self.lastReadError = err
                    NSLog("[better-macOS] read menu of %@ failed: %@", app.name, String(describing: err))
                }
            }
        }
    }

    /// 决定「这次按键要不要弹吐司」的全部策略都在这里。
    ///
    /// 三条规则，按顺序：
    /// 1. **没按修饰键的一律不弹**——那是打字。每按一个字母弹一次是不可用的产品。
    /// 2. **单按修饰键本身不弹**——⌘、⇧ 单独按下不是动作。
    /// 3. **有修饰键但没绑定菜单的，弹一句「未绑定」**——
    ///    对迁移者来说「我按了但没反应」是最需要解释的状态，
    ///    而这正是 Windows 肌肉记忆落空的时刻。
    private func handleKey(_ stroke: KeyStroke) {
        let hudEnabled = UserDefaults.standard.object(forKey: "hud.enabled") as? Bool ?? true
        guard hudEnabled else { return }

        // 规则 1：纯普通键 = 打字，不打扰
        guard !stroke.modifiers.isEmpty else { return }

        let resolution = resolver.resolve(stroke: stroke, in: lastSnapshot)
        let showUnknown = UserDefaults.standard.object(forKey: "hud.show-unknown") as? Bool ?? false

        let content: ToastContent
        if let action = resolution.action {
            content = ToastContent(action: action,
                                   combo: stroke.combo,
                                   windowsEquivalent: nil,
                                   sourceApp: resolution.appName)
        } else if showUnknown {
            content = ToastContent(action: stroke.combo + " 未绑定菜单动作",
                                   combo: "",
                                   windowsEquivalent: nil,
                                   sourceApp: resolution.appName)
        } else {
            return   // 规则 3 默认关闭：不解释未绑定键，避免噪音
        }
        hud.show(content)
    }

    // MARK: 快捷键面板

    @objc private func openBrowser() {
        guard let snapshot = lastSnapshot else {
            let a = NSAlert()
            a.messageText = "读不到当前 App 的菜单"
            switch lastReadError {
            case .noPermission:
                a.informativeText = "需要先在「系统设置 → 隐私与安全性 → 辅助功能」里授权 better-macOS。"
                a.addButton(withTitle: "去授权")
                a.addButton(withTitle: "取消")
                if a.runModal() == .alertFirstButtonReturn {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            case .cannotComplete:
                a.informativeText = "这个 App 没有及时响应菜单查询，或者权限尚未生效。\n如果刚授权完，请先退出并重新启动 better-macOS。"
                a.addButton(withTitle: "好")
                a.runModal()
            case .noMenuBar:
                a.informativeText = "这个 App 没有菜单栏（后台 App 或自绘界面）。"
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

    @objc private func openPrefs() {
        if prefs == nil { prefs = PreferencesWindow(registry: registry) }
        NSApp.activate(ignoringOtherApps: true)
        prefs?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 首次引导

    private func showFirstRunGuidance() {
        let a = NSAlert()
        a.messageText = "better-macOS 需要「辅助功能」权限"
        a.informativeText = """
        它只做一件事：读取当前 App 的菜单，看看你刚触发了哪个动作。

        它**不会**记录你按了哪些键，也不会把你按了什么发送出去——只读动作名。
        未授权时，菜单栏图标还在，但什么都不会发生。

        点击「去授权」后，在系统设置里勾选 better-macOS 即可。
        """
        a.addButton(withTitle: "去授权")
        a.addButton(withTitle: "稍后")
        if a.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }
}

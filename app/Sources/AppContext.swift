import AppKit
import ApplicationServices

// MARK: - 权限

/// TCC 的唯一入口。
///
/// **两条铁律**（都有实测依据）：
/// 1. `AXIsProcessTrusted()` 的返回值不能当作「能不能收到事件」的判据——
///    未授权时 `tapCreate`/`addGlobalMonitor` 都会返回非 nil 而零投递。
/// 2. `AXIsProcessTrustedWithOptions(prompt: true)` **不保证把本 App 加进授权列表**。
///    ad-hoc 签名、首次运行、或系统正在忙的时候，用户点进系统设置可能看到一个空列表，
///    然后以为是 App 坏了。**所以主引导必须是「自己把 App 拖进去」**，
///    系统弹窗只作为尝试，不能作为唯一路径。
enum Permissions {

    /// 辅助功能是否已授权。`prompt: false` 不弹窗，可安全轮询。
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 本 App 的 bundle 路径（拖拽引导要展示给用户，也可能被拖进系统设置）。
    static var appBundleURL: URL? {
        Bundle.main.bundleURL
    }

    /// 尝试让系统弹出授权提示。
    /// **返回后必须重新检查 `hasAccessibility`，不能假设它成功了。**
    @discardableResult
    static func attemptSystemPrompt() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 打开「隐私与安全性 → 辅助功能」面板。
    static func openAccessibilitySettings() {
        // 这个 URL scheme 在 macOS 13+ 仍有效；失败时退回到打开「隐私与安全性」根页。
        let deep = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(deep)
    }

    /// 在 Finder 里定位到 App 本体——拖拽引导需要用户能抓到它。
    static func revealAppInFinder() {
        guard let url = appBundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 前台 App 跟踪

/// 深模块：调用方只问「现在前台是哪个 App」，它负责感知变化、去重、排除自己。
///
/// **为什么必须轮询而不是订阅通知**（实测，2026-11-08）：
/// `NSWorkspace.didActivateApplicationNotification` 只在 App **自己是活跃 App**
/// 时才会投递。而我们是 `LSUIElement` 菜单栏 App，几乎永远不是活跃 App——
/// 实测切换 Finder ↔ Chrome 期间，监听器收到 **0 条**通知，而同样的切换
/// 用轮询 `frontmostApplication` 100% 能拿到。
///
/// 这是这个模块存在的全部理由：把「事件不可靠」这件丑陋的事实关在接口后面。
final class FrontmostAppTracker {
    struct App {
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    private(set) var current: App?
    private var timer: Timer?
    var onChange: ((App?) -> Void)?

    /// 轮询间隔。300ms 在「切换 App 后马上按键」这个场景下够快，
    /// 而 `frontmostApplication` 是本地 IPC，开销可以忽略。
    private let interval: TimeInterval = 0.3

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
        // 让计时器在菜单打开、窗口拖动等 RunLoop 模式下也能跑
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if ProcessInfo.processInfo.environment["BMAC_DEBUG_TRACKER"] != nil {
            FileHandle.standardError.write("POLL: \(app.localizedName ?? "?") pid=\(app.processIdentifier)\n".data(using: .utf8)!)
        }
        let pid = app.processIdentifier
        // 忽略自己：不该给自己弹提示，也不该读自己的菜单。
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let next = App(pid: pid,
                       name: app.localizedName ?? "未知 App",
                       bundleID: app.bundleIdentifier ?? "unknown")
        if let cur = current, cur.pid == next.pid, cur.bundleID == next.bundleID { return }
        current = next
        onChange?(next)
    }
}

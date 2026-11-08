import AppKit
import ApplicationServices

// MARK: - 权限

/// TCC 的唯一入口。**返回值不能作为「能不能收到事件」的判据**——
/// 本机实测：未授权时 `tapCreate`/`addGlobalMonitor` 都会返回非 nil 而零投递。
/// 所以这里只负责「权限状态」的读取与引导。
enum Permissions {

    /// 辅助功能是否已授权。`prompt: false` 不弹窗，可安全轮询。
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 引导用户去系统设置。**不保证返回后已授权**——用户可能只是看了一眼。
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// 直接打开「隐私与安全性 → 辅助功能」面板。
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 前台 App 跟踪

/// 深模块：调用方只问「现在前台是哪个 App」，
/// 它负责通知订阅、去重、以及把自己排除掉。
final class FrontmostAppTracker {
    struct App {
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    private(set) var current: App?
    private var observers: [NSObjectProtocol] = []
    var onChange: ((App?) -> Void)?

    func start() {
        refresh()
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(c.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
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

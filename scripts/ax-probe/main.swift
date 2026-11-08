// AX 探针：回答 issue #6 的三个问题，只依赖公开 API。
//
// 用法：
//   ./scripts/ax-probe/run.sh                       # 默认跑微信/飞书/Obsidian/Chrome/Safari/Finder
//   ./scripts/ax-probe/run.sh --app 微信 --n 10     # 指定 App、次数
//   ./scripts/ax-probe/run.sh --timeouts 0.5,2,5    # 对比不同 messaging timeout
//   ./scripts/ax-probe/run.sh --cold                # 冷启动模式：等 App 刚出现的那几秒
//
// ⚠️ 从终端跑会**继承终端的辅助功能授权**（README「AXIsProcessTrusted() 会撒谎」），
// 所以本探针测到的是「最大授权」状态：任何失败都不是权限造成的，而是 App 自身的响应。
// 这个特性对 #6 反而是好事——它把「权限」这个变量排除掉了。

import AppKit
import ApplicationServices
import Foundation

// MARK: - 进程枚举

struct ProcInfo {
    let pid: pid_t
    let path: String
    let ppid: pid_t
}

func allProcesses() -> [ProcInfo] {
    let cap = proc_listallpids(nil, 0)
    guard cap > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(cap) + 64)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    var out: [ProcInfo] = []
    let bufLen = 4096
    var buf = [CChar](repeating: 0, count: bufLen)
    for i in 0 ..< Int(n) {
        let pid = pids[i]
        guard pid > 0 else { continue }
        let r = proc_pidpath(pid, &buf, UInt32(bufLen))
        let path = r > 0 ? String(cString: buf) : ""
        var bsd = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ppid = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sz) == sz ? pid_t(bsd.pbi_ppid) : 0
        out.append(ProcInfo(pid: pid, path: path, ppid: ppid))
    }
    return out
}

// MARK: - AX 读取

/// 一次读取的结果：err 原值 + 耗时 + 派生项。
struct ReadResult {
    let err: AXError
    let ms: Double
    /// 只有 err == .success 时才有意义
    let menuBarExists: Bool
    /// 菜单栏顶层项数量（-1 = 没读到）
    let topLevelCount: Int
    let timedOut: Bool

    var ok: Bool { err == .success && menuBarExists }
    var errName: String { AXProbe.errName(err) }
    /// messaging timeout 超时的错误码就是 kAXErrorCannotComplete（-25204）。
    /// 但同一个错误码也可能是 App 明确拒绝。区分方式：耗时 ≈ timeout 值 → 超时。
    var looksLikeTimeout: Bool { timedOut }
}

enum AXProbe {
    static func errName(_ e: AXError) -> String {
        switch e {
        case .success: return "success(0)"
        case .failure: return "failure(-25200)"
        case .illegalArgument: return "illegalArgument(-25201)"
        case .invalidUIElement: return "invalidUIElement(-25202)"
        case .invalidUIElementObserver: return "invalidUIElementObserver(-25203)"
        case .cannotComplete: return "cannotComplete(-25204)"
        case .attributeUnsupported: return "attributeUnsupported(-25205)"
        case .actionUnsupported: return "actionUnsupported(-25206)"
        case .notificationUnsupported: return "notificationUnsupported(-25207)"
        case .notImplemented: return "notImplemented(-25208)"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered(-25209)"
        case .notificationNotRegistered: return "notificationNotRegistered(-25210)"
        case .apiDisabled: return "apiDisabled(-25211)"
        case .noValue: return "noValue(-25212)"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported(-25213)"
        case .notEnoughPrecision: return "notEnoughPrecision(-25214)"
        @unknown default: return "unknown(\(e.rawValue))"
        }
    }

    static func readMenuBar(pid: pid_t, timeout: Float) -> ReadResult {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, timeout)

        var mbRef: CFTypeRef?
        let t0 = DispatchTime.now().uptimeNanoseconds
        let err = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        // 「耗时接近 timeout」是超时的指纹；远小于 timeout 的 -25204 是 App 主动拒绝。
        let looksTimedOut = err == .cannotComplete && ms >= Double(timeout) * 1000 * 0.8

        guard err == .success, let mb = mbRef else {
            return ReadResult(err: err, ms: ms, menuBarExists: false,
                              topLevelCount: -1, timedOut: looksTimedOut)
        }

        let bar = mb as! AXUIElement
        var kidsRef: CFTypeRef?
        let kerr = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef)
        let count = (kerr == .success ? (kidsRef as? [AXUIElement])?.count : nil) ?? -1
        return ReadResult(err: .success, ms: ms, menuBarExists: true,
                          topLevelCount: count, timedOut: false)
    }

    /// 模拟 MenuInventory.snapshot()：读菜单栏 → 递归数 AXMenuItem。
    /// 用于确认「菜单栏读到了，但里面是空的」这种半失败状态。
    static func countItems(pid: pid_t, timeout: Float) -> (items: Int, withKeys: Int, err: AXError) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, timeout)
        var mbRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef)
        guard err == .success, let mb = mbRef else { return (0, 0, err) }

        var items = 0, withKeys = 0
        func attr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
        }
        func children(_ el: AXUIElement) -> [AXUIElement] {
            (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        }
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            for c in children(el) {
                let role = (attr(c, kAXRoleAttribute as String) as? String) ?? ""
                if role == "AXMenuItem" {
                    items += 1
                    let ch = (attr(c, kAXMenuItemCmdCharAttribute as String) as? String) ?? ""
                    let vk = (attr(c, kAXMenuItemCmdVirtualKeyAttribute as String) as? NSNumber)?.intValue
                    let gl = (attr(c, kAXMenuItemCmdGlyphAttribute as String) as? NSNumber)?.intValue
                    if !ch.isEmpty || vk != nil || gl != nil { withKeys += 1 }
                } else if role == "AXMenu" || role == "AXMenuBarItem" {
                    walk(c, depth: depth + 1)
                }
            }
        }
        for barItem in children(mb as! AXUIElement) { walk(barItem, depth: 0) }
        return (items, withKeys, .success)
    }
}

// MARK: - App 查找

struct AppGroup {
    let name: String
    let pids: [pid_t]
    /// pid → 可执行文件绝对路径（展示用）
    let pathOf: [pid_t: String]
}

/// 按 .app bundle 路径前缀把同名进程归类，再关联到 NSRunningApplication。
/// 「微信有几个进程」这个问题不能靠 `pgrep -x WeChat` 回答——
/// Electron 系一个 App 会拉一窝 helper（渲染器、GPU、插件宿主）。
func findApps(matching needle: String) -> [AppGroup] {
    let procs = allProcesses()
    var byBundle: [String: [ProcInfo]] = [:]
    for p in procs where !p.path.isEmpty {
        guard let r = p.path.range(of: ".app/") else { continue }
        let bundle = String(p.path[p.path.startIndex ..< r.lowerBound]) + ".app"
        byBundle[bundle, default: []].append(p)
    }
    var out: [AppGroup] = []
    for (bundle, list) in byBundle {
        let name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        guard name.localizedCaseInsensitiveContains(needle) else { continue }
        out.append(AppGroup(name: name,
                            pids: list.map(\.pid).sorted(),
                            pathOf: Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0.path) })))
    }
    return out.sorted { $0.name < $1.name }
}

func runningApp(pid: pid_t) -> NSRunningApplication? {
    NSRunningApplication(processIdentifier: pid)
}

func policyName(_ p: NSApplication.ActivationPolicy) -> String {
    switch p {
    case .regular: return "regular"
    case .accessory: return "accessory"
    case .prohibited: return "prohibited"
    @unknown default: return "unknown"
    }
}

// MARK: - 主流程

struct Options {
    var needles: [String] = ["微信", "飞书", "Obsidian", "Chrome", "Safari", "Finder"]
    var n = 10
    var interval = 0.2
    var timeouts: [Float] = [2.0]
    var cold = false
    var coldSeconds = 0.0
}

func parseArgs() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--app":
            if !args.isEmpty { o.needles = args.removeFirst().split(separator: ",").map(String.init) }
        case "--n":
            if !args.isEmpty { o.n = Int(args.removeFirst()) ?? o.n }
        case "--interval":
            if !args.isEmpty { o.interval = Double(args.removeFirst()) ?? o.interval }
        case "--timeouts":
            if !args.isEmpty {
                o.timeouts = args.removeFirst().split(separator: ",").compactMap { Float($0) }
                if o.timeouts.isEmpty { o.timeouts = [2.0] }
            }
        case "--cold":
            o.cold = true
        default:
            break
        }
    }
    return o
}

func fmt(_ ms: Double) -> String { String(format: "%6.1f", ms) }

let opts = parseArgs()

print("== AX 探针 ==")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("AXIsProcessTrusted() = \(AXIsProcessTrusted())  ← 终端启动会继承终端授权，见 README")
if let front = NSWorkspace.shared.frontmostApplication {
    print("frontmost = \(front.localizedName ?? "?") pid=\(front.processIdentifier)")
}
print(String(repeating: "─", count: 100))

var totalFail = 0
var totalReads = 0

for needle in opts.needles {
    let groups = findApps(matching: needle)
    if groups.isEmpty {
        print("\n### \(needle)：未找到进程")
        continue
    }
    for g in groups {
        print("\n### \(g.name)  （进程数 \(g.pids.count)）")

        // 每个进程的身份
        for pid in g.pids {
            let ra = runningApp(pid: pid)
            let pol = ra.map { policyName($0.activationPolicy) } ?? "不是 NSRunningApplication（辅助进程）"
            let active = (ra?.isActive ?? false) ? " ACTIVE" : ""
            let hidden = (ra?.isHidden ?? false) ? " hidden" : ""
            print("  pid \(pid)  policy=\(pol)\(active)\(hidden)")
            print("           \(g.pathOf[pid] ?? "")")
        }

        // 主进程：有 menu bar 的那个通常是有 bundleIdentifier 的 regular app 里 pid 最小的
        let regular = g.pids.compactMap { runningApp(pid: $0) }.filter { $0.activationPolicy == .regular }
        let target = regular.first?.processIdentifier ?? g.pids.first!
        let targetRA = runningApp(pid: target)
        print("  → 被测主进程 pid=\(target) name=\(targetRA?.localizedName ?? "?") bundle=\(targetRA?.bundleIdentifier ?? "?")")

        for timeout in opts.timeouts {
            print("  timeout=\(timeout)s")
            var okCount = 0
            var failCount = 0
            var msList: [Double] = []
            for i in 1 ... opts.n {
                let r = AXProbe.readMenuBar(pid: target, timeout: timeout)
                totalReads += 1
                if r.ok { okCount += 1 } else { failCount += 1; totalFail += 1 }
                msList.append(r.ms)
                let flag = r.ok ? "" : (r.looksLikeTimeout ? "  ← 超时指纹（耗时≈timeout）" : "  ← 快速返回，不是超时")
                print("    [\(String(format: "%2d", i))/\(opts.n)] err=\(r.errName)  \(fmt(r.ms))ms  topLevel=\(r.topLevelCount)\(flag)")
                if i < opts.n { Thread.sleep(forTimeInterval: opts.interval) }
            }
            let avg = msList.reduce(0, +) / Double(msList.count)
            let maxMs = msList.max() ?? 0
            print("    小结: ok=\(okCount)/\(opts.n)  fail=\(failCount)  avg=\(fmt(avg))ms  max=\(fmt(maxMs))ms")
        }

        // 完整快照（和产品走同一条路径）
        let snap = AXProbe.countItems(pid: target, timeout: opts.timeouts.first ?? 2.0)
        print("  完整快照: err=\(AXProbe.errName(snap.err)) items=\(snap.items) withKeys=\(snap.withKeys)")
    }
}

print(String(repeating: "─", count: 100))
print("总计: \(totalReads) 次读取，失败 \(totalFail) 次")

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// issue #3 的取证探针：**只读**地观察 scrollWheel 事件流，把判断「滚轮 vs 触控板」
/// 可能用到的每个字段原样打印出来。
///
/// 刻意不复用 `Corrections.swift` 的判据实现——探针如果跑被测代码自己的判断，
/// 它只能证明「代码和自己一致」，回答不了「真实滚轮是 0 还是 1」。
///
/// 由 main.swift 的 `--probe-scroll` 触发，封装见 `./app/probe-scroll.sh`：
///   ./app/probe-scroll.sh 15            # 真实设备（必须有人的手去滚）
///   ./app/probe-scroll.sh --exercise 8  # 合成事件（只验证字段通路与分支，不能代替真实设备）
enum ScrollProbe {

    // MARK: - 一个滚动事件的完整字段快照

    struct Fields {
        let continuous: Int64      // kCGScrollWheelEventIsContinuous (88)   ← 现行判据
        let delta1: Int64          // kCGScrollWheelEventDeltaAxis1 (11)      行/格
        let delta2: Int64          // kCGScrollWheelEventDeltaAxis2 (12)
        let point1: Int64          // kCGScrollWheelEventPointDeltaAxis1 (96) 像素
        let point2: Int64          // kCGScrollWheelEventPointDeltaAxis2 (97)
        let fixed1: Double         // kCGScrollWheelEventFixedPtDeltaAxis1 (93)
        let fixed2: Double         // kCGScrollWheelEventFixedPtDeltaAxis2 (94)
        let phase: Int64           // kCGScrollWheelEventScrollPhase (99)     手势阶段，触控板才有
        let momentum: Int64        // kCGScrollWheelEventMomentumPhase (123)  惯性阶段，触控板才有
        let count: Int64           // kCGScrollWheelEventScrollCount (100)
        let instant: Int64         // kCGScrollWheelEventInstantMouser (14)
        let srcPID: Int64          // kCGEventSourceUnixProcessID (41)
        let srcUserData: Int64     // kCGEventSourceUserData (42)
        let senderID: UInt64?      // IOHIDEventGetSenderID（SPI，仅真实硬件事件可得）

        /// 现行判据：连续 = 触控板 / Magic Mouse，离散 = 传统滚轮
        var looksLikeTrackpad: Bool { continuous != 0 }
        /// 备用判据：只有手势设备才会带 phase / momentum
        var hasGesturePhase: Bool { phase != 0 || momentum != 0 }
    }

    // MARK: - SPI（dlsym，拿不到就静默降级成 nil）

    private typealias CopyIOHIDEventFn = @convention(c) (CGEvent?) -> OpaquePointer?
    private typealias GetSenderIDFn = @convention(c) (OpaquePointer?) -> UInt64

    private static let copyIOHIDEvent: CopyIOHIDEventFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventCopyIOHIDEvent") else { return nil }
        return unsafeBitCast(p, to: CopyIOHIDEventFn.self)
    }()

    private static let getSenderID: GetSenderIDFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetSenderID") else { return nil }
        return unsafeBitCast(p, to: GetSenderIDFn.self)
    }()

    static var spiAvailable: Bool { copyIOHIDEvent != nil && getSenderID != nil }

    // MARK: - 读字段

    static func fields(of e: CGEvent) -> Fields {
        var senderID: UInt64?
        if let copy = copyIOHIDEvent, let get = getSenderID, let hid = copy(e) {
            senderID = get(hid)
        }
        return Fields(
            continuous: e.getIntegerValueField(.scrollWheelEventIsContinuous),
            delta1: e.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            delta2: e.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            point1: e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            point2: e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixed1: e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixed2: e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            phase: e.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentum: e.getIntegerValueField(.scrollWheelEventMomentumPhase),
            count: e.getIntegerValueField(.scrollWheelEventScrollCount),
            instant: e.getIntegerValueField(.scrollWheelEventInstantMouser),
            // 这两个 field 的 Swift 名字在不同 SDK 里被剥过前缀（.sourceUnixProcessID vs
            // .eventSourceUnixProcessID），直接用头文件里的原始编号最稳。
            srcPID: e.getIntegerValueField(CGEventField(rawValue: 41)!),
            srcUserData: e.getIntegerValueField(CGEventField(rawValue: 42)!),
            senderID: senderID
        )
    }

    static func line(_ f: Fields, index: Int, elapsed: TimeInterval) -> String {
        let sender = f.senderID.map { String(format: "0x%llx", $0) } ?? "nil"
        return String(
            format: "[%6.2fs] #%-3d cont=%lld d1=%+lld d2=%+lld p1=%+lld p2=%+lld "
                  + "f1=%+.2f f2=%+.2f phase=%lld mom=%lld count=%lld instant=%lld "
                  + "srcPID=%lld srcUD=%lld senderID=%@ → %@",
            elapsed, index, f.continuous, f.delta1, f.delta2, f.point1, f.point2,
            f.fixed1, f.fixed2, f.phase, f.momentum, f.count, f.instant,
            f.srcPID, f.srcUserData, sender,
            f.looksLikeTrackpad ? "放行(判据=触控板)" : "翻转(判据=滚轮)")
    }

    // MARK: - 入口

    static func run(arguments: [String]) -> Int32 {
        var seconds: Double = 15
        var exercise = false
        var rest = arguments
        if rest.contains("--verify-flip") {
            return runVerifyFlip(arguments: rest)
        }
        if let i = rest.firstIndex(of: "--exercise") {
            exercise = true
            rest.remove(at: i)
        }
        if let i = rest.firstIndex(where: { Double($0) != nil }), let v = Double(rest[i]), v > 0 {
            seconds = min(v, 600)
        }

        print("═══ better-macOS scroll probe（GitHub issue #3）═══")
        print("AXIsProcessTrusted    = \(AXIsProcessTrusted())   ← 必须是 true，否则 tap 装得上但零投递")
        print("CGPreflightPostEvent  = \(CGPreflightPostEventAccess())   ← 只有 --exercise 模式才需要")
        print("IOHID SPI             = \(spiAvailable ? "可用（senderID 可读）" : "不可用（senderID 恒 nil）")")
        print("模式                  = \(exercise ? "合成事件（只验证字段通路与分支）" : "真实设备（必须人手去滚）")")
        print("时长                  = \(seconds)s")
        print("────────────────────────────────────────────────────────────────────")
        fflush(stdout)

        probeSamples = []
        probeStartedAt = Date()

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // 只读：探针绝不改事件，避免污染被测行为
            eventsOfInterest: mask,
            callback: scrollProbeTapCallback,
            userInfo: nil
        ) else {
            print("✗ tapCreate 失败 —— 事件监听装不上（多半是辅助功能权限没授予运行探针的进程）。")
            return 2
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("✗ CFMachPortCreateRunLoopSource 失败")
            return 2
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if exercise { postSynthetic() }

        let deadline = Date().addingTimeInterval(seconds)
        var lastTick = Int.min
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.2, false)
            let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
            if left != lastTick, left >= 0, left % 5 == 0 || left <= 3 {
                lastTick = left
                FileHandle.standardError.write("\r… 还剩 \(left)s（Ctrl-C 可提前结束）".data(using: .utf8)!)
            }
        }
        FileHandle.standardError.write("\r".data(using: .utf8)!)

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)

        summarize(exercise: exercise)
        return probeSamples.isEmpty ? 1 : 0
    }

    // MARK: - 端到端翻转验证（不需要人手，测「正在运行的 App 到底改了没」）

    /// 这个模式回答一个和真实设备不同的问题：
    /// **装了 tap 的 App 有没有真的改写事件**。
    ///
    /// 做法：本进程在 `.tailAppendEventTap`（队尾）挂一个只读 tap，
    /// 而 better-macOS 的修正 tap 在 `.headInsertEventTap`（队首）。
    /// 于是同一个事件先被 App 改，再被我们看到——看到的 delta 就是改后的值。
    ///
    /// 性质：**合成事件**。它能证明「权限 → 投递 → 改写」这条链通，
    /// 但证明不了真实滚轮会被判成 cont=0（那要 `--exercise` 之外的人手）。
    static func runVerifyFlip(arguments: [String]) -> Int32 {
        print("═══ better-macOS scroll probe：端到端翻转验证 ═══")
        print("前置条件（任一不满足，下面必然看到未翻转，别当 bug）：")
        print("  1. better-macOS 正在运行且开关已开（日志里应有 restored correction / SCROLL correction ON）")
        print("  2. 本进程有辅助功能权限")
        print("AXIsProcessTrusted   = \(AXIsProcessTrusted())")
        print("CGPreflightPostEvent = \(CGPreflightPostEventAccess())")

        // --enable-tap：本进程自己实例化产品里的 ScrollDirectionCorrection 并在**当前** runloop
        // 上真的装一次 tap。用于把「判据对不对」和「tap 有没有装上」两个问题分开。
        var localCorrection: ScrollDirectionCorrection?
        if arguments.contains("--enable-tap") {
            print("\n自装 tap 模式：直接调用 app/Sources/Corrections.swift 里的 enable()")
            let c = ScrollDirectionCorrection()
            c.disable()                      // 清掉 init() 从 UserDefaults 恢复的 isOn
            switch c.enable() {
            case .success:
                print("  enable() → success（tap 已装到本进程 runloop 的队首）")
            case .failure(let e):
                print("  enable() → failure: \(e.message)")
            }
            localCorrection = c
        }
        print("────────────────────────────────────────────────────────────────────")
        fflush(stdout)

        flipSamples = []
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,   // 关键：队尾，才能看到 App 改写后的值
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: verifyFlipTapCallback,
            userInfo: nil
        ) else {
            print("✗ tapCreate 失败（辅助功能权限？）")
            return 2
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return 2 }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // 投一个「滚轮语义」的事件：cont=0、delta1=+3、point1=+24、fixed1=+3
        let posted = Fields(continuous: 0, delta1: 3, delta2: 0, point1: 24, point2: 0,
                            fixed1: 3, fixed2: 0, phase: 0, momentum: 0, count: 0,
                            instant: 0, srcPID: 0, srcUserData: 0, senderID: nil)
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                           wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 24)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3)
            print("投递前（合成）：cont=0 d1=+3 p1=+24 f1=+3.00")
            e.post(tap: .cghidEventTap)
        }
        CFRunLoopRunInMode(.defaultMode, 1.0, false)

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)
        let onCount = localCorrection?.flippedCount ?? -1
        let seenCount = localCorrection?.seenScroll ?? -1
        localCorrection?.disable()

        print("\n队尾观察到 \(flipSamples.count) 个事件：")
        guard let seen = flipSamples.last else {
            print("✗ 一个都没看到 —— 事件没有回到本进程，无法判定。")
            print("  若 CGPreflightPostEvent=false，先在「辅助功能」里给本进程授权。")
            return 1
        }
        print("  " + line(seen, index: flipSamples.count, elapsed: 0))
        let flipped = seen.delta1 == -posted.delta1
        print("")
        if flipped {
            print("✓ d1 从 +3 变成 \(seen.delta1) —— App 的 tap **确实在投递并改写**事件。")
            print("  → 「打开开关后鼠标没反应」不是 tap 没装/零投递，问题在判据或放大链路。")
        } else {
            print("✗ d1 仍是 \(seen.delta1)（未被翻转）。两种可能，用下面的命令区分：")
            print("  a) App 没运行 / 开关没开 / 那份 App 没授权 → 见日志 grep 'SCROLL\\|restored' ~/Library/Logs/better-macOS.log")
            print("  b) App 在跑但 tap 零投递（TCC 授权的是另一份 .app）")
        }
        if let first = flipSamples.first, flipSamples.count > 1 {
            print("  （共 \(flipSamples.count) 个，第一个 d1=\(first.delta1)）")
        }
        if arguments.contains("--enable-tap") {
            print("  产品代码内部的计数器：seenScroll=\(seenCount) flippedCount=\(onCount)")
            print("  （seenScroll=0 说明事件根本没进 handle()——tap 装了但零投递）")
        }
        return flipped ? 0 : 1
    }

    // MARK: - 汇总

    private static func summarize(exercise: Bool) {
        print("\n────────────────────────────────────────────────────────────────────")
        guard !probeSamples.isEmpty else {
            print("0 个事件。按概率排序的可能原因：")
            print("  1. 辅助功能权限没给到「运行探针的那个进程」→ tap 装得上但零投递")
            print("  2. 没有人真的滚（探针不会自己动）")
            print("  3. 设备事件走了别的通路（例如旋钮被系统吃掉）")
            return
        }
        print("事件总数 = \(probeSamples.count)")
        let groups = Dictionary(grouping: probeSamples, by: { $0.continuous })
        for (cont, group) in groups.sorted(by: { $0.key < $1.key }) {
            let phases = Set(group.map(\.phase)).sorted()
            let momentum = Set(group.map(\.momentum)).sorted()
            let senders = Set(group.compactMap(\.senderID))
            let senderText = senders.isEmpty
                ? "nil"
                : senders.map { String(format: "0x%llx", $0) }.sorted().joined(separator: ",")
            let pids = Set(group.map(\.srcPID)).sorted()
            print("  cont=\(cont): \(group.count) 个 → 现行判据判定"
                  + "「\(cont != 0 ? "触控板：原样放行" : "滚轮：翻转")」"
                  + " | phase=\(phases) momentum=\(momentum) srcPID=\(pids) senderID=\(senderText)")
        }
        let gesture = probeSamples.filter(\.hasGesturePhase).count
        print("  带手势 phase/momentum 的事件: \(gesture) 个（只有手势设备会带）")
        if exercise {
            print("\n⚠️ 以上是**合成事件**。它能证明「判据对 continuous 的分支」与「字段读写通路」成立，")
            print("   但**不能**证明真实滚轮鼠标的 continuous 是 0 —— 那必须让人的手去滚（去掉 --exercise）。")
        }
    }

    // MARK: - 合成事件（只验证字段通路与分支，不产生设备结论）

    private static func postSynthetic() {
        print("── 合成事件：post 两个 scrollWheel，一个 cont=0，一个 cont=1 ──")
        let cases: [(String, Int64, CGScrollEventUnit)] = [
            ("离散（滚轮语义，行单位）", 0, .line),
            ("连续（触控板语义，像素单位）", 1, .pixel),
        ]
        for (label, cont, unit) in cases {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: unit,
                                  wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) else { continue }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: cont)
            print("→ 投递 \(label)：期望 cont=\(cont)")
            e.post(tap: .cghidEventTap)
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
        print("── 合成事件结束 ──")
    }
}


// MARK: - C 回调（必须是全局函数：tapCreate 的 callback 是 C 函数指针，不能捕获上下文）

private var probeSamples: [ScrollProbe.Fields] = []
private var probeStartedAt = Date()

private func scrollProbeTapCallback(proxy: CGEventTapProxy,
                                    type: CGEventType,
                                    event: CGEvent,
                                    refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    let f = ScrollProbe.fields(of: event)
    probeSamples.append(f)
    print(ScrollProbe.line(f, index: probeSamples.count,
                           elapsed: Date().timeIntervalSince(probeStartedAt)))
    fflush(stdout)
    return Unmanaged.passUnretained(event)
}


// MARK: - 端到端翻转验证的回调与状态

private var flipSamples: [ScrollProbe.Fields] = []

private func verifyFlipTapCallback(proxy: CGEventTapProxy,
                                   type: CGEventType,
                                   event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    flipSamples.append(ScrollProbe.fields(of: event))
    return Unmanaged.passUnretained(event)
}

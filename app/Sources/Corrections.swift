import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - 修正项（L2 的接口）

/// **深模块的接口就是这四件事**：我是谁、我开着吗、打开、还原。
///
/// 每个「系统痛点修正」都实现它。UI 遍历这些修正项自动生成开关，
/// 加一个新痛点不需要改 UI 一行代码——这是这个接口存在的全部理由。
protocol Correction {
    /// 稳定的标识符，用于持久化。改名会让用户的设置丢失。
    var id: String { get }
    /// 面板上的标题
    var title: String { get }
    /// 一句话解释：为什么系统做不到、我们做了什么
    var subtitle: String { get }
    /// 这个修正需要什么权限（没有就不该打开）
    var requiredPermission: Permission { get }
    /// 当前是否生效
    var isOn: Bool { get }
    /// 打开。失败时返回错误描述。
    func enable() -> Result<Void, CorrectionError>
    /// 还原到系统默认。**每个修正都必须能彻底撤回。**
    func disable()
    /// 数值型参数（如反转的强度），没有就返回 nil
    var options: [CorrectionOption] { get }
    func setOption(_ id: String, value: Double)
}

enum Permission {
    case none
    case accessibility

    var isGranted: Bool {
        switch self {
        case .none: return true
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    var description: String {
        switch self {
        case .none: return "无需权限"
        case .accessibility: return "需要辅助功能权限"
        }
    }
}

struct CorrectionOption {
    enum Kind { case toggle, stepper(min: Double, max: Double) }
    let id: String
    let title: String
    let kind: Kind
}

struct CorrectionError: Error {
    let message: String
}

// MARK: - 修正 1：鼠标滚轮与触控板方向分离

/// 系统只有一个全局键 `com.apple.swipescrolldirection`，鼠标和触控板共用。
/// 我们不改那个键（改了会影响别人），而是在事件流上**只翻转鼠标滚轮**，
/// 触控板事件一个字段都不碰——所以触控板的惯性滚动完全不受影响。
final class ScrollDirectionCorrection: Correction {

    let id = "scroll.separate-direction"
    let title = "鼠标与触控板方向分离"
    let subtitle = "系统只有一个「自然滚动」开关，鼠标和触控板被绑在一起。打开后：触控板保持自然滚动，鼠标滚轮恢复 Windows 方向。"
    let requiredPermission: Permission = .accessibility
    let options: [CorrectionOption] = [
        CorrectionOption(id: "horizontal", title: "同时反转横向滚动（Shift+滚轮）", kind: .toggle)
    ]

    private(set) var isOn = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reverseHorizontal = false
    private var consecutiveTimeouts = 0
    private static var live: ScrollDirectionCorrection?

    init() {
        ScrollDirectionCorrection.live = self
        // 注意：**不要**在这里 `isOn = Self.wasEnabled`。
        // isOn 的语义是「tap 此刻装上了吗」，不是「用户上次开着吗」。
        // 两者混同会让 restoreSaved() → enable() 撞上
        // `guard !isOn else { return .success(()) }` 提前返回：
        // tap 一次都没装，但开关在 UI 上亮着，用户以为开了（issue #3）。
    }

    func enable() -> Result<Void, CorrectionError> {
        guard !isOn else { return .success(()) }
        guard requiredPermission.isGranted else {
            return .failure(CorrectionError(message: "需要先在「系统设置 → 隐私与安全性 → 辅助功能」中授权。"))
        }

        // .defaultTap 才能改写事件；只关心 scrollWheel，不碰键盘（那样会要 Input Monitoring）。
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: nil
        ) else {
            return .failure(CorrectionError(message: "无法创建事件监听。请确认已授予辅助功能权限，然后重启本 App。"))
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isOn = true
        Self.wasEnabled = true
        NSLog("[better-macOS] scroll correction ON")
        Diag.log("SCROLL correction ON (tap installed)")
        return .success(())
    }

    func disable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        isOn = false
        Self.wasEnabled = false
        NSLog("[better-macOS] scroll correction OFF")
        Diag.log("SCROLL correction OFF")
    }

    func setOption(_ id: String, value: Double) {
        if id == "horizontal" { reverseHorizontal = value != 0 }
    }

    /// 事件回调：O(1)、不分配、不加锁——否则会被系统判定超时停掉。
    /// 诊断计数（供 /tmp 日志与设置页显示）
    private(set) var seenScroll = 0
    private(set) var flippedCount = 0
    private(set) var continuousCount = 0

    fileprivate func handle(event: CGEvent) -> CGEvent? {
        guard event.type == .scrollWheel else { return event }
        seenScroll += 1

        // 判据与翻转在 ScrollCorrectionMath 里（纯函数，可被自测覆盖）。
        // 触控板**原样返回**，一个字段都不改，所以惯性滚动不受影响。
        let decision = ScrollCorrectionMath.decide(event, reverseHorizontal: reverseHorizontal)
        if !decision.shouldFlip { continuousCount += 1; return event }
        flippedCount += 1
        return event
    }

    fileprivate func tapWasDisabled() {
        // 系统会在回调超时/用户输入过快时停掉 tap，必须自己恢复。
        consecutiveTimeouts += 1
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if consecutiveTimeouts > 5 {
            NSLog("[better-macOS] scroll tap repeatedly disabled, giving up")
            disable()
        }
    }

    fileprivate func tapDelivered() {
        consecutiveTimeouts = 0
    }

    // 持久化
    private static let key = "correction.scroll.separate-direction.enabled"
    /// 只由 `enable()` / `disable()` 写入；读取一律走 `restoreSaved()` 的显式判断。
    /// （`isOn` 才是「现在生效吗」，两者不是一回事——见 `init()` 的注释。）
    private static var wasEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var shared: ScrollDirectionCorrection? { live }
}

private func scrollTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let corr = ScrollDirectionCorrection.shared else {
        return Unmanaged.passUnretained(event)
    }
    // 系统停用 tap 的通知不是真事件，必须先恢复再返回
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        corr.tapWasDisabled()
        return Unmanaged.passUnretained(event)
    }
    if type == .scrollWheel {
        corr.tapDelivered()
        if let out = corr.handle(event: event) {
            return Unmanaged.passUnretained(out)
        }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 判据与翻转（纯函数，可测）

/// 把「这个滚动事件算不算滚轮、要不要翻」从 event tap 里剥出来。
///
/// 放在独立类型里只有一个理由：**判据是 issue #3 的争议核心，必须能被自测覆盖**。
/// 埋在 event tap 回调里的分支，除了真机手滚没有别的验证手段。
enum ScrollCorrectionMath {

    /// `kCGScrollWheelEventIsContinuous` 在 CGEventTypes.h 里的编号。
    /// 探针（ScrollProbe）用同一个字段，这里锁死数值防止哪天读错 field。
    static let isContinuousFieldRawValue = 88

    struct Decision {
        /// true = 判为传统滚轮，需要翻转
        let shouldFlip: Bool
        /// true = 横向也要翻
        let flipHorizontal: Bool
        /// 判据当时的原始字段值，便于诊断
        let continuous: Int64
    }

    /// 判定 + 翻转，一步到位（判错就翻错的代价由自测兜住）。
    /// 返回值带原始字段值，方便调用方计数和诊断。
    @discardableResult
    static func decide(_ event: CGEvent, reverseHorizontal: Bool) -> Decision {
        let continuous = event.getIntegerValueField(
            CGEventField(rawValue: UInt32(isContinuousFieldRawValue))!)
        let decision = Decision(shouldFlip: continuous == 0,
                                flipHorizontal: reverseHorizontal,
                                continuous: continuous)
        if decision.shouldFlip { flip(event, horizontal: reverseHorizontal) }
        return decision
    }

    /// 三组 delta 一起翻。
    /// **只翻 Delta 会让系统反推 PointDelta（约 8×），平滑滚动就没了** ——
    /// 这是 Scroll Reverser 源码注释里明写的坑。
    static func flip(_ event: CGEvent, horizontal: Bool) {
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let pdy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fdy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -dy)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pdy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fdy)

        guard horizontal else { return }
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let pdx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fdx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -dx)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pdx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fdx)
    }
}

// MARK: - 修正注册表

/// UI 只跟这一个东西打交道。
final class CorrectionRegistry {
    private(set) var corrections: [Correction] = []
    let scroll = ScrollDirectionCorrection()
    let openFile = OpenFileCorrection()

    init() {
        corrections = [scroll, openFile]
    }

    func restoreSaved() {
        for c in corrections where UserDefaults.standard.bool(forKey: "correction.\(c.id).enabled") {
            switch c.enable() {
            case .success:
                NSLog("[better-macOS] restored correction: %@", c.id)
            case .failure(let e):
                NSLog("[better-macOS] failed to restore %@: %@", c.id, e.message)
            }
        }
    }

    /// 由 AppDelegate 注入：打开拖拽式权限引导。
    /// CorrectionRegistry 自己不该知道 UI 长什么样。
    var onNeedPermission: (() -> Void)?

    func setEnabled(_ c: Correction, _ on: Bool) {
        if on {
            switch c.enable() {
            case .success:
                UserDefaults.standard.set(true, forKey: "correction.\(c.id).enabled")
            case .failure(let e):
                let a = NSAlert()
                a.messageText = "无法打开「\(c.title)」"
                a.informativeText = e.message
                a.addButton(withTitle: "去授权")
                a.addButton(withTitle: "取消")
                if a.runModal() == .alertFirstButtonReturn {
                    onNeedPermission?()
                }
            }
        } else {
            c.disable()
            UserDefaults.standard.set(false, forKey: "correction.\(c.id).enabled")
        }
    }
}

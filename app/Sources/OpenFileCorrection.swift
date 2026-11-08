import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - 修正 2：Finder 里回车 = 打开

/// Windows 肌肉记忆：选中文件按 Enter = 打开。
/// macOS：Enter = **进入重命名**，打开要 ⌘O。迁移用户在 Finder 里连按几次回车
/// 会把文件名改坏——这是后果最重的一条（research/pain-points.md F8）。
///
/// ## 为什么这条必须走事件改写
///
/// 实测（本机 macOS 26，AX 遍历 Finder 菜单）：Finder 的「重新命名」菜单项
/// `AXMenuItemCmdChar` 为空、**没有键位等价物**——Enter=重命名 是 Finder 内部
/// 处理的，不是菜单快捷键。所以：
/// - 系统设置里能给「打开」*叠加*一个 ⌘↵（社区公认做法，也是本目录原来的指引）
/// - 但**没有任何官方途径能取消 Enter=重命名**
///
/// 想真正复刻 Windows，只能在事件流上拦 Return 并转成 ⌘O。这也是为什么
/// 调研文档把这条标成「零权限」是错的：改写按键必须有辅助功能权限。
///
/// ## 与 `ScrollDirectionCorrection` 的两处刻意不同
/// 1. **`init()` 不读 UserDefaults**。`isOn` 的语义是「现在真的生效吗」，
///    持久化恢复是 `CorrectionRegistry.restoreSaved()` 的职责。issue #3 的
///    根因正是把「上次开着」写进 `isOn`，导致 `restoreSaved → enable()` 早退。
/// 2. 不自己存 `wasEnabled` 键。registry 已经按 `correction.<id>.enabled`
///    持久化，实现里再来一份就是两个真相源。
final class OpenFileCorrection: Correction {

    let id = "finder.enter-to-open"
    let title = "Finder 里回车 = 打开文件"
    let subtitle = "系统把 Enter 绑给「重命名」，而且没有任何开关能改。打开后：选中文件按回车直接打开，和在 Windows 里一致。要重命名请用菜单「文件 → 重新命名」或 ⌘R。"
    let requiredPermission: Permission = .accessibility

    /// 协议要求声明，但**目前没有任何 UI 消费它**（Preferences 只渲染
    /// title / subtitle / requiredPermission / isOn）。这里留空是诚实的：
    /// 见报告「options / setOption 是否过度设计」。
    let options: [CorrectionOption] = []
    func setOption(_ id: String, value: Double) { /* 没有可设置的项 */ }

    /// 现在是否真的在拦按键。**不是**「用户上次开着吗」。
    private(set) var isOn = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var consecutiveTimeouts = 0

    /// 前台是否是 Finder。0.3s 轮询缓存，**不在 tap 回调里调 NSWorkspace**：
    /// 回调必须 O(1) 返回，超时会被系统停掉 tap。
    private var finderPoll: Timer?
    fileprivate var finderIsFrontmost = false
    fileprivate var finderPid: pid_t = 0

    fileprivate static var live: OpenFileCorrection?

    // 诊断计数（供日志排查；和滚动修正一样不进 UI）
    private(set) var seenKeyDown = 0
    private(set) var openedCount = 0
    private(set) var passedThroughCount = 0

    init() {
        OpenFileCorrection.live = self
    }

    // MARK: Correction

    func enable() -> Result<Void, CorrectionError> {
        guard !isOn else { return .success(()) }
        guard requiredPermission.isGranted else {
            return .failure(CorrectionError(
                message: "需要先在「系统设置 → 隐私与安全性 → 辅助功能」中授权，才能改写 Finder 里的回车键。"))
        }

        // 只要 keyDown：不是要读你打了什么字，是要在事件到达 Finder 前把它换掉。
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: openFileTapCallback,
            userInfo: nil
        ) else {
            return .failure(CorrectionError(
                message: "无法创建键盘监听。请确认已授予辅助功能权限，然后重启本 App。"))
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        refreshFinderState()
        startFinderPolling()

        isOn = true
        NSLog("[better-macOS] open-file correction ON")
        Diag.log("OPENFILE correction ON (enter→⌘O in Finder)")
        return .success(())
    }

    func disable() {
        stopFinderPolling()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        consecutiveTimeouts = 0
        isOn = false
        NSLog("[better-macOS] open-file correction OFF")
        Diag.log("OPENFILE correction OFF")
    }

    // MARK: 前台 App 轮询

    private func startFinderPolling() {
        finderPoll?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshFinderState()
        }
        RunLoop.main.add(t, forMode: .common)
        finderPoll = t
    }

    private func stopFinderPolling() {
        finderPoll?.invalidate()
        finderPoll = nil
    }

    fileprivate func refreshFinderState() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        finderIsFrontmost = isFinder
        finderPid = isFinder ? app.processIdentifier : 0
    }

    // MARK: 事件回调

    /// 只对「可能是 Finder 里的纯 Return」做后续判断，其余按键一条指令返回。
    fileprivate func handle(keyDown event: CGEvent) -> CGEvent? {
        seenKeyDown += 1
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard FinderReturnRule.isReturnKey(keyCode) else { return event }
        guard FinderReturnRule.modifiers(from: event.flags).isEmpty else { return event }
        guard finderIsFrontmost else {
            passedThroughCount += 1
            return event
        }

        // 走到这里才做 AX 查询（每按一次回车一次，中位 ~0.07ms）。
        let (sheetOpen, focusedRole) = queryFinderFocus()

        switch FinderReturnRule.decide(
            keyCode: keyCode,
            modifiers: FinderReturnRule.modifiers(from: event.flags),
            frontmostIsFinder: finderIsFrontmost,
            sheetOpen: sheetOpen,
            focusedRole: focusedRole
        ) {
        case .openSelection:
            openedCount += 1
            postCommandO()
            return nil                    // 吞掉 Return：Finder 不会进重命名
        case .passThrough:
            passedThroughCount += 1
            return event                  // 保持系统原语义
        }
    }

    /// 查「Finder 这会儿是不是在编辑文本 / 有没有弹窗」。
    /// 超时设得很短：这是 event tap 回调，绝不能被 AX 拖住。
    private func queryFinderFocus() -> (sheetOpen: Bool, focusedRole: String?) {
        guard finderPid != 0 else { return (false, nil) }
        let app = AXUIElementCreateApplication(finderPid)
        AXUIElementSetMessagingTimeout(app, 0.05)

        var focusedRole: String?
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
           let el = v {
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &r) == .success {
                focusedRole = r as? String
            }
        }

        // `kAXSheetsAttribute` 在 Swift 里没有导出（头文件有、模块没有），只能写字面量。
        // 效果一样：AX 属性的名字就是字符串。
        var sheetOpen = false
        var w: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success,
           let win = w {
            var s: CFTypeRef?
            if AXUIElementCopyAttributeValue(win as! AXUIElement, "AXSheets" as CFString, &s) == .success,
               let sheets = s as? [AXUIElement] {
                sheetOpen = !sheets.isEmpty
            }
        }
        return (sheetOpen, focusedRole)
    }

    /// 合成 ⌘O —— 走的是 Finder 自己的「打开」菜单项，和用户手按 ⌘O 等价。
    private func postCommandO() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 31, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 31, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    fileprivate func tapWasDisabled() {
        // 系统在回调超时 / 用户输入过快时会停掉 tap，必须自己恢复。
        consecutiveTimeouts += 1
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if consecutiveTimeouts > 5 {
            NSLog("[better-macOS] open-file tap repeatedly disabled, giving up")
            Diag.log("OPENFILE tap repeatedly disabled → disable()")
            disable()
        }
    }

    fileprivate func tapDelivered() { consecutiveTimeouts = 0 }
}

// MARK: - 纯决策核心

/// **不碰 event tap、不碰 AX 的纯函数**：只回答「这一下 Return 该放行还是该改写」。
///
/// 抽出来的理由和 issue #3 里 `ScrollCorrectionMath` 一样：埋在 tap 回调里的分支
/// 除了真机手按没法验证，而这里恰恰是最容易写坏的地方——
/// 放行错一个 case，用户就在重命名时把文件打开了。
enum FinderReturnRule {

    enum Decision: Equatable {
        /// 放行，保持系统原语义。
        case passThrough(PassReason)
        /// 吞掉 Return，改发 ⌘O。
        case openSelection
    }

    enum PassReason: String, Equatable {
        case notPlainReturn     // 不是 Return，或者带修饰键
        case notFinderFrontmost // 前台不是 Finder
        case sheetOpen          // Finder 有弹窗：Return 属于弹窗的默认按钮
        case textEditing        // 正在编辑文本：重命名、搜索框、前往文件夹
    }

    /// Return = 36，小键盘 Enter = 76。两个都该打开（Windows 也一样）。
    static func isReturnKey(_ keyCode: Int) -> Bool { keyCode == 36 || keyCode == 76 }

    /// 只认 ⌘⇧⌥⌃ 这四类修饰键；Fn、小键盘标志位不算「带修饰键」。
    static func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var m: ShortcutModifiers = []
        if flags.contains(.maskCommand)   { m.insert(.command) }
        if flags.contains(.maskShift)     { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl)   { m.insert(.control) }
        return m
    }

    /// 文本类角色：重命名时 Finder 的 field editor 会报 AXTextField，
    /// 搜索框报 AXSearchField，前往文件夹之类的输入框报 AXTextField/AXComboBox。
    static func isTextRole(_ role: String) -> Bool {
        role == "AXTextField" || role == "AXTextArea"
            || role == "AXSearchField" || role == "AXComboBox"
    }

    static func decide(keyCode: Int,
                       modifiers: ShortcutModifiers,
                       frontmostIsFinder: Bool,
                       sheetOpen: Bool,
                       focusedRole: String?) -> Decision {
        guard isReturnKey(keyCode), modifiers.isEmpty else { return .passThrough(.notPlainReturn) }
        guard frontmostIsFinder else { return .passThrough(.notFinderFrontmost) }
        guard !sheetOpen else { return .passThrough(.sheetOpen) }
        if let role = focusedRole, isTextRole(role) { return .passThrough(.textEditing) }
        return .openSelection
    }
}

private func openFileTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let corr = OpenFileCorrection.live else {
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        corr.tapWasDisabled()
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        corr.tapDelivered()
        if let out = corr.handle(keyDown: event) {
            return Unmanaged.passUnretained(out)
        }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

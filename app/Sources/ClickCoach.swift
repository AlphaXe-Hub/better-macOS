import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - 点击教练（L1 学习层的第三条通道）
//
// ## 它解决什么问题
//
// 前两条通道（按键吐司、快捷键面板）都假设用户**已经在用快捷键**了：
// 按键吐司要等他按下去才教，面板要他自己去查。可迁移期的真实状态是
// 反过来的——他在用鼠标「点点点」：菜单里翻到「文件 → 存储」，点它。
//
// 那一刻是**最好的教学时机**：他刚刚明确表达了意图（我要存储），
// 而答案（⌘S）就在他手指旁边两厘米。错过就没了。
//
// ## 为什么只认菜单项
//
// 实测（scripts/click-probe/，2026-11-08，macOS 26.5）：
// - 菜单项：命中的就是 AXMenuItem 本身，AXMenuItemCmdChar +
//   AXMenuItemCmdModifiers 直接告诉你快捷键是什么。**不需要猜。**
// - 工具栏按钮：我枚举了文本编辑和访达窗口的整棵 AX 树，AXButton /
//   AXPopUpButton 的 title / description / help **全是空的**。它们是自绘图标，
//   没有无障碍标签。想把「这个按钮 = ⌘B」对上，只能靠猜位置或猜名字，
//   而猜错比不说更伤（用户会开始不信任这个工具）。
//
// 所以：**只教菜单项，其余一律沉默**。覆盖「点点点」的主战场，且 100% 准确。
//
// ## 为什么用 CGEventTap 而不是 NSEvent 全局监听
//
// 这是实测踩出来的（同一批探针）：
// - NSEvent.addGlobalMonitorForEvents(.leftMouseDown) 在**菜单跟踪期间一条都收不到**
//   ——菜单展开时 AppKit 进了自己的模态跟踪循环，事件根本不到我们的监听器。
//   而「点菜单」恰恰是这个功能唯一有效的场景，所以那条路等于完全不可用。
// - CGEvent.tapCreate(.cgSessionEventTap, .listenOnly) 能收到，包括菜单跟踪期间。
//
// listenOnly 是关键：只旁听，不改写事件。教练永远不替用户做决定。
//
// ## 为什么同步查询
//
// 命中测试实测 0.31 ms 中位 / 0.64 ms 最大（普通区域 p95 0.58 ms）。
// 同步做的好处是**确定性**：事件到达我们时菜单一定还开着；异步延迟哪怕 20ms，
// 弹出的菜单可能已经因为别的操作关掉了，查询就会落空。
// 0.3ms 用户完全无感，不值得为异步换来不确定性。

/// 一次「可以教」的点击。
struct ClickLesson: Equatable {
    /// 菜单项标题，例如「存储」
    let action: String
    /// 快捷键，例如「⌘S」
    let combo: String
    /// 这个菜单属于谁
    let appName: String
    /// 同一个教具的去重键：(App, 动作)。不同 App 的同名动作要分开计数。
    var key: String { "\(appName)|\(action)" }
}

/// 深模块：喂它一件「用户刚点过的菜单项」，它决定要不要开口教。
///
/// 调用方（AppDelegate）只需要在 `onTeach` 上挂一个吐司。它不知道
/// CGEventTap 存在、不知道衰减怎么算、不需要在任何回调里做判断。
final class ClickCoach {

    /// 该教的时候调用。**已经在主线程**。
    var onTeach: ((ClickLesson) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// 每个 (App, 动作) 已经教过几次。进程内有效即可——重启后重新数，
    /// 用户本来也会重新注意到这个功能。
    private var taught: [String: Int] = [:]

    /// 自测观察口（app/test.sh / e2e）：教练是否真的挂上了事件通道。
    /// 这个功能最危险的失败模式是「装了但零投递」——和 KeyWatcher 当初一样，
    /// 所以必须留一个能被断言的开关状态。
    var isHealthy: Bool { isRunning && tap != nil }

    /// 同一个动作最多教几次。取 3：通常第 2 次就记住了，
    /// 给第 3 次留一点冗余。
    static let maxTeachPerAction = 3

    // MARK: 生命周期

    func start() {
        stop()
        guard AXIsProcessTrusted() else {
            Diag.log("CLICKCOACH 未启动：没有辅助功能权限")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)

        // .cgSessionEventTap 而不是 .cghidEventTap：会话层足够看到菜单点击，
        // 权限门槛也低（只需要辅助功能，不需要输入监控）。
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let coach = Unmanaged<ClickCoach>.fromOpaque(userInfo).takeUnretainedValue()
                coach.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diag.log("CLICKCOACH CGEventTap 创建失败（权限或环境限制）")
            return
        }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        // .commonModes 必须：菜单跟踪时主 runloop 进的是 NSEventTrackingRunLoopMode，
        // 只注册 default mode 的 source 在那一刻是停摆的（这和 NSEvent 监听收不到
        // 是同一个根因的两种表现）。
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        isRunning = true
        Diag.log("CLICKCOACH started trusted=true tap=ok")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    /// 系统会因为我们回调太慢而停掉 tap。
    /// 命中测试实测 0.3ms，正常不会触发；但目标 App 卡死时 AX 调用会超时，
    /// 所以必须能自愈，否则教练会静默失效而用户不知道。
    private func reenableIfNeeded() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Diag.log("CLICKCOACH tap 被系统停用，已重新启用")
    }

    // MARK: 事件处理

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenableIfNeeded()
            return
        case .leftMouseDown, .rightMouseDown:
            break
        default:
            return
        }

        guard let lesson = Self.inspect(at: event.location) else { return }

        // 衰减：同一个动作教够次数就闭嘴。
        // 用户学会了不需要再提；没学会说明这个入口没用（或者是误触），
        // 继续弹只会让他去关掉整个功能——那时连有用的提示也没了。
        let n = taught[lesson.key, default: 0]
        guard n < Self.maxTeachPerAction else { return }
        taught[lesson.key] = n + 1

        Diag.log("CLICKTEACH \(lesson.appName) \"\(lesson.action)\" → \(lesson.combo)（第 \(n + 1) 次）")
        DispatchQueue.main.async { [weak self] in
            self?.onTeach?(lesson)
        }
    }

    // MARK: 查询（纯函数，可单测）

    /// 屏幕坐标 → 可教的课。返回 nil 表示「这一下不值得教」。
    ///
    /// 独立成 static 是为了让 `--click-at x y` 这个调试入口能直接复用，
    /// 也方便在没有事件通道的环境里验证判定逻辑。
    static func inspect(at point: CGPoint) -> ClickLesson? {
        let system = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        // 不教自己的界面：用户点我们自己的菜单项，不该反过来教他。
        guard pid != getpid() else { return nil }

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"

        // 命中点常常落在菜单项内部的文字上，真正的 AXMenuItem 在父级。
        // 往上最多找 5 层——再深就不是菜单项了。
        var current: AXUIElement? = hit
        for _ in 0..<5 {
            guard let el = current else { break }
            if string(el, kAXRoleAttribute) == "AXMenuItem" {
                return lesson(from: el, appName: appName)
            }
            guard let parent = copy(el, kAXParentAttribute) else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }

    /// 从一个 AXMenuItem 读出这节课。没有快捷键的菜单项返回 nil。
    private static func lesson(from item: AXUIElement, appName: String) -> ClickLesson? {
        let title = string(item, kAXTitleAttribute) ?? ""
        guard !title.isEmpty else { return nil }

        // 分隔符 / 子菜单标题这类项没有键位，会被下面挡掉。
        guard let char = string(item, "AXMenuItemCmdChar"), !char.isEmpty else {
            // 少数菜单项只有虚拟键码（方向键、功能键），没有可显示的字符。
            // 这种情况我们说不出「按什么」，教不了，沉默。
            return nil
        }

        let modifiers = (copy(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
        return ClickLesson(action: title,
                           combo: comboString(char: char, carbonModifiers: modifiers),
                           appName: appName)
    }

    /// Carbon 位掩码 → `⌘⇧S` 这种形式。
    ///
    /// **⌘ 是隐含的**：这个掩码只记录「除 ⌘ 以外的修饰键」，
    /// 只有 bit3（8）置位才表示「显式地没有 ⌘」。
    static func comboString(char: String, carbonModifiers mods: Int) -> String {
        var s = ""
        if (mods & 8) == 0 { s += "⌘" }
        if (mods & 4) != 0 { s += "⌃" }
        if (mods & 2) != 0 { s += "⌥" }
        if (mods & 1) != 0 { s += "⇧" }
        return s + char.uppercased()
    }

    // MARK: AX 小工具

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let s = copy(el, attr) as? String, !s.isEmpty else { return nil }
        return s
    }
}

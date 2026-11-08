import AppKit

// 入口。`LSUIElement` 让 Dock 里没有图标；
// `setActivationPolicy(.accessory)` 是它的代码侧双保险。
//
// 调试参数（开发期用，不影响正常启动）：
//   --open-guide    启动后直接打开「迁移清单」
//   --open-prefs    启动后直接打开设置
//   --open-browser  启动后直接打开快捷键面板
//   --open-permission 启动后直接打开权限引导
//   --e2e-toast     吐司端到端自证：合成按键 → 断言窗口真的在 Window Server 屏幕上
//                   （由 app/e2e.sh 调用；全部 PASS 才 exit 0）
// 点击教练取证：在指定屏幕坐标跑一次命中判定并打印结果，然后退出。
// **必须放在 NSApplication 初始化之前**——否则会走完整启动流程，
// 进程挂在事件循环里不退出（踩过：命令行下去 60 秒还在跑）。
//   --click-at 210 51
if let i = CommandLine.arguments.firstIndex(of: "--click-at"),
   i + 2 < CommandLine.arguments.count,
   let x = Double(CommandLine.arguments[i + 1]),
   let y = Double(CommandLine.arguments[i + 2]) {
    let lesson = ClickCoach.inspect(at: CGPoint(x: x, y: y))
    if let lesson {
        print("CLICK-AT (\(Int(x)),\(Int(y))) → app=\(lesson.appName) action=\"\(lesson.action)\" combo=\(lesson.combo)")
    } else {
        print("CLICK-AT (\(Int(x)),\(Int(y))) → 没有可教的快捷键")
    }
    exit(lesson == nil ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

let args = CommandLine.arguments
if args.contains("--open-guide")   { delegate.debugOpenTarget = .guide }
if args.contains("--open-prefs")   { delegate.debugOpenTarget = .prefs }
if args.contains("--open-browser") { delegate.debugOpenTarget = .browser }
// 用整张 Windows 对照表演示例 App（前台菜单凑不齐映射时验证面板版式）
if args.contains("--open-browser-demo") {
    delegate.debugOpenTarget = .browser
    delegate.debugDemoBrowser = true
}
if args.contains("--open-permission") { delegate.debugOpenTarget = .permission }

// issue #3 取证探针：只读观察 scrollWheel 字段，跑完直接退出（见 ScrollProbe.swift）
if args.contains("--probe-scroll") { exit(ScrollProbe.run(arguments: args)) }
if args.contains("--e2e-toast") { delegate.debugToastE2E = true }

if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    delegate.debugRenderTo = args[i + 1]
}
// 只渲染一张带 Windows 对照的吐司（吐司 1.6s 后自动消失，需要专门的出口留证据）
if let i = args.firstIndex(of: "--render-toast"), i + 1 < args.count {
    delegate.debugRenderToastTo = args[i + 1]
}

app.run()

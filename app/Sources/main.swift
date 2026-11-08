import AppKit

// 入口。`LSUIElement` 让 Dock 里没有图标；
// `setActivationPolicy(.accessory)` 是它的代码侧双保险。
//
// 调试参数（开发期用，不影响正常启动）：
//   --open-guide    启动后直接打开「迁移清单」
//   --open-prefs    启动后直接打开设置
//   --open-browser  启动后直接打开快捷键面板
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

let args = CommandLine.arguments
if args.contains("--open-guide")   { delegate.debugOpenTarget = .guide }
if args.contains("--open-prefs")   { delegate.debugOpenTarget = .prefs }
if args.contains("--open-browser") { delegate.debugOpenTarget = .browser }

if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    delegate.debugRenderTo = args[i + 1]
}

app.run()

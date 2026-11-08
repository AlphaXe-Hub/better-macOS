import AppKit

// 入口。`LSUIElement` 让 Dock 里没有图标；
// `setActivationPolicy(.accessory)` 是它的代码侧双保险。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

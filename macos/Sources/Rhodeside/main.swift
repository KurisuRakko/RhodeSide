import AppKit

// 手动设 delegate（不用 @main）：SwiftPM 可执行目标 + 自己组装的 .app
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()

// laserguide-dev エントリポイント。
//
// LSUIElement (メニューバーのみ) 相当の挙動を setActivationPolicy(.accessory) で得る。
// swift run 経由の起動でも Dock アイコンなし、メニューバー常駐で振る舞う。
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

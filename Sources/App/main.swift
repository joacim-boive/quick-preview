import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = appDelegate
app.run()

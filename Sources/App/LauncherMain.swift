import Cocoa

@main
enum LauncherMain {
    static func main() {
        let launcherApplication = NSApplication.shared
        let launcherAppDelegate = MainActor.assumeIsolated { LauncherAppDelegate() }
        launcherApplication.delegate = launcherAppDelegate
        launcherApplication.run()
    }
}

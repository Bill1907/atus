import AppKit

// Plain AppKit lifecycle: the whole UI is the status item, so there is no SwiftUI
// `App` scene (a placeholder `Settings` scene would open an empty window at launch).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, also when launched via `swift run` without Info.plist.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(store: UsageStore())
    }
}

// Global, so the delegate outlives `run()`; NSApplication only holds it weakly.
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()

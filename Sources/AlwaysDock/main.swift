import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar-only app: no Dock icon of its own, no app menu.
    app.setActivationPolicy(.accessory)
    app.run()
}

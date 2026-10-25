import AppKit

/// Reads and tweaks the system Dock through its preferences domain (com.apple.dock).
@MainActor
enum SystemDock {
    private static let domain = "com.apple.dock"
    private static let savedStateKey = "savedSystemDockState"
    /// An auto-hide delay this long means the system Dock never slides back in.
    private static let hiddenDelay = 1000.0

    static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    static var orientation: String { value("orientation") as? String ?? "bottom" }

    static var persistentApps: [[String: Any]] { value("persistent-apps") as? [[String: Any]] ?? [] }

    static var isHidden: Bool {
        (value("autohide") as? Bool ?? false) && (value("autohide-delay") as? Double ?? 0) >= hiddenDelay
    }

    /// The system Dock reserves space on the screen it is currently shown on, so that screen's
    /// visible frame is inset on the Dock's edge. When it auto-hides, no screen is inset.
    static func occupies(_ screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let threshold: CGFloat = 10
        return visible.minY - frame.minY > threshold
            || visible.minX - frame.minX > threshold
            || frame.maxX - visible.maxX > threshold
    }

    /// Auto-hides the system Dock with a huge delay. The user's own values are saved first so `restore()` can put them back.
    static func hide() {
        guard !isHidden else { return }
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: savedStateKey) == nil {
            var saved: [String: Any] = [:]
            saved["autohide"] = value("autohide")
            saved["autohide-delay"] = value("autohide-delay")
            defaults.set(saved, forKey: savedStateKey)
        }
        run("/usr/bin/defaults", "write", domain, "autohide", "-bool", "true")
        run("/usr/bin/defaults", "write", domain, "autohide-delay", "-float", "\(hiddenDelay)")
        run("/usr/bin/killall", "Dock")
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: savedStateKey) else { return }
        if let autohide = saved["autohide"] as? Bool {
            run("/usr/bin/defaults", "write", domain, "autohide", "-bool", autohide ? "true" : "false")
        } else {
            run("/usr/bin/defaults", "delete", domain, "autohide")
        }
        if let delay = saved["autohide-delay"] as? Double {
            run("/usr/bin/defaults", "write", domain, "autohide-delay", "-float", "\(delay)")
        } else {
            run("/usr/bin/defaults", "delete", domain, "autohide-delay")
        }
        defaults.removeObject(forKey: savedStateKey)
        run("/usr/bin/killall", "Dock")
    }

    private static func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

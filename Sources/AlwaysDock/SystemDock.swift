import AppKit
import os

/// Reads and tweaks the system Dock through its preferences domain (com.apple.dock).
@MainActor
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedStateKey = "savedSystemDockState"
    /// An auto-hide delay this long means the system Dock never slides back in.
    private static let hiddenDelay = 1000.0
    private static let log = Logger(subsystem: "io.dogy.AlwaysDock", category: "SystemDock")

    static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
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
        apply(["autohide": true, "autohide-delay": hiddenDelay])
        log.notice("Hid the system Dock")
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: savedStateKey) else { return }
        // A value missing from the saved state was unset before, so it is removed again.
        apply(["autohide": saved["autohide"], "autohide-delay": saved["autohide-delay"]])
        defaults.removeObject(forKey: savedStateKey)
        log.notice("Restored the system Dock")
    }

    /// Writes the values (nil removes one) and restarts the Dock, which reads them only at launch.
    private static func apply(_ values: [String: Any?]) {
        for (key, value) in values {
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
        }
        guard CFPreferencesAppSynchronize(domain) else {
            log.error("Could not save the system Dock's preferences")
            return
        }
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        killall.standardError = FileHandle.nullDevice
        do {
            try killall.run()
            killall.waitUntilExit()
            if killall.terminationStatus != 0 { log.error("killall Dock exited with \(killall.terminationStatus)") }
        } catch {
            log.error("Could not restart the Dock: \(error.localizedDescription, privacy: .public)")
        }
    }
}

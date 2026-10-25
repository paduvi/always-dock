import AppKit

struct DockItem: Equatable {
    let url: URL
    let bundleID: String?
    let name: String
    let isPinned: Bool
    let isRunning: Bool
}

/// The dock's contents: Finder, the apps pinned in the system Dock, then running apps that are not pinned.
@MainActor
final class DockModel: NSObject {
    static let didChange = Notification.Name("AlwaysDock.modelDidChange")

    private(set) var items: [DockItem] = []
    private var iconCache: [URL: NSImage] = [:]
    private var refreshTimer: Timer?

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        // Pinned apps live in the system Dock's preferences, which post no change notification.
        refreshTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(reload),
                                            userInfo: nil, repeats: true)
        reload()
    }

    @objc func reload() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil && $0 != NSRunningApplication.current
        }
        var newItems: [DockItem] = []
        var seen = Set<String>()

        for pinned in pinnedApps() {
            guard seen.insert(pinned.bundleID ?? pinned.url.path).inserted else { continue }
            let isRunning = running.contains { Self.app($0, matches: pinned.url, bundleID: pinned.bundleID) }
            newItems.append(DockItem(url: pinned.url, bundleID: pinned.bundleID, name: pinned.name,
                                     isPinned: true, isRunning: isRunning))
        }
        for app in running {
            guard let url = app.bundleURL, seen.insert(app.bundleIdentifier ?? url.path).inserted else { continue }
            let name = app.localizedName ?? FileManager.default.displayName(atPath: url.path)
            newItems.append(DockItem(url: url, bundleID: app.bundleIdentifier, name: name,
                                     isPinned: false, isRunning: true))
        }

        guard newItems != items else { return }
        items = newItems
        iconCache = iconCache.filter { entry in newItems.contains { $0.url == entry.key } }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func icon(for item: DockItem) -> NSImage {
        if let icon = iconCache[item.url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        iconCache[item.url] = icon
        return icon
    }

    func runningApp(for item: DockItem) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { Self.app($0, matches: item.url, bundleID: item.bundleID) }
    }

    /// Launches the app, or brings it forward (reopening a window if it has none), like a Dock click.
    func open(_ item: DockItem, files: [URL] = []) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            let workspace = NSWorkspace.shared
            let app = files.isEmpty
                ? try? await workspace.openApplication(at: item.url, configuration: configuration)
                : try? await workspace.open(files, withApplicationAt: item.url, configuration: configuration)
            // Clicks on a non-activating panel leave AlwaysDock inactive, and since macOS 14 an inactive
            // app's activation requests may be declined. If so, become active ourselves and hand it over.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let app, !app.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            app.activate(options: [])
        }
    }

    private static func app(_ app: NSRunningApplication, matches url: URL, bundleID: String?) -> Bool {
        if let bundleID, app.bundleIdentifier == bundleID { return true }
        return app.bundleURL?.standardizedFileURL == url.standardizedFileURL
    }

    private func pinnedApps() -> [(url: URL, bundleID: String?, name: String)] {
        var apps: [(url: URL, bundleID: String?, name: String)] = []
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            apps.append((finder, "com.apple.finder", FileManager.default.displayName(atPath: finder.path)))
        }
        for tile in SystemDock.persistentApps {
            guard let data = tile["tile-data"] as? [String: Any],
                  let fileData = data["file-data"] as? [String: Any],
                  let string = fileData["_CFURLString"] as? String else { continue }
            // _CFURLStringType 0 is a plain POSIX path, 15 a file:// URL.
            let url = (fileData["_CFURLStringType"] as? Int) == 0
                ? URL(fileURLWithPath: string)
                : URL(string: string)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let bundleID = data["bundle-identifier"] as? String ?? Bundle(url: url)?.bundleIdentifier
            let name = data["file-label"] as? String ?? FileManager.default.displayName(atPath: url.path)
            apps.append((url, bundleID, name))
        }
        return apps
    }
}

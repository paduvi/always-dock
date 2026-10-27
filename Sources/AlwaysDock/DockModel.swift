import AppKit

struct DockItem: Equatable {
    let url: URL
    let bundleID: String?
    let name: String
    let isPinned: Bool
    let isRunning: Bool
}

/// A running app that shows in the Dock, with the details the dock needs copied out once: reading any
/// property of an NSRunningApplication can cost a round trip to LaunchServices.
private struct RegularApp {
    let app: NSRunningApplication
    let pid: pid_t
    let url: URL
    let bundleID: String?
    let name: String
}

/// The dock's contents: Finder, the apps pinned in the system Dock, then running apps that are not pinned.
@MainActor
final class DockModel: NSObject {
    static let didChange = Notification.Name("AlwaysDock.modelDidChange")

    private(set) var items: [DockItem] = []
    private var iconCache: [URL: NSImage] = [:]
    private var refreshTimer: Timer?
    /// Running apps that show in the Dock, in launch order. Polling every running process for its activation
    /// policy would take a round trip to LaunchServices each, so the list is kept up to date through KVO.
    private var regularApps: [RegularApp] = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var policyObservations: [pid_t: NSKeyValueObservation] = [:]

    override init() {
        super.init()
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications,
                                                            options: [.initial, .new, .old]) { [weak self] _, change in
            let added = change.newValue ?? [], removed = change.oldValue ?? []
            MainActor.assumeIsolated { self?.runningAppsChanged(added: added, removed: removed) }
        }
        // Pinned apps live in the system Dock's preferences, which post no change notification.
        refreshTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(reload),
                                            userInfo: nil, repeats: true)
        reload()
    }

    private func runningAppsChanged(added: [NSRunningApplication], removed: [NSRunningApplication]) {
        for app in removed {
            let pid = app.processIdentifier
            policyObservations[pid] = nil
            regularApps.removeAll { $0.pid == pid }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in added {
            let pid = app.processIdentifier
            guard pid != ownPID else { continue }
            policyObservations[pid] = app.observe(\.activationPolicy) { [weak self] app, _ in
                MainActor.assumeIsolated { self?.policyChanged(app) }
            }
            if app.activationPolicy == .regular { addRegular(app) }
        }
        reload()
    }

    /// Apps switch policy when they show or hide their Dock icon.
    private func policyChanged(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let isRegular = app.activationPolicy == .regular
        guard isRegular != regularApps.contains(where: { $0.pid == pid }) else { return }
        if isRegular { addRegular(app) } else { regularApps.removeAll { $0.pid == pid } }
        reload()
    }

    private func addRegular(_ app: NSRunningApplication) {
        guard let url = app.bundleURL?.standardizedFileURL else { return }
        regularApps.append(RegularApp(app: app, pid: app.processIdentifier, url: url, bundleID: app.bundleIdentifier,
                                      name: app.localizedName ?? FileManager.default.displayName(atPath: url.path)))
    }

    @objc func reload() {
        var newItems: [DockItem] = []
        var seen = Set<String>()

        for pinned in pinnedApps() {
            guard seen.insert(pinned.bundleID ?? pinned.url.path).inserted else { continue }
            let isRunning = regularApps.contains { Self.app($0, matches: pinned.url, bundleID: pinned.bundleID) }
            newItems.append(DockItem(url: pinned.url, bundleID: pinned.bundleID, name: pinned.name,
                                     isPinned: true, isRunning: isRunning))
        }
        for app in regularApps {
            guard seen.insert(app.bundleID ?? app.url.path).inserted else { continue }
            newItems.append(DockItem(url: app.url, bundleID: app.bundleID, name: app.name,
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
        regularApps.first { Self.app($0, matches: item.url, bundleID: item.bundleID) }?.app
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

    /// Both URLs are standardized when they are read, since standardizing touches the disk.
    private static func app(_ app: RegularApp, matches url: URL, bundleID: String?) -> Bool {
        if let bundleID, app.bundleID == bundleID { return true }
        return app.url == url
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
            guard let url = url?.standardizedFileURL, FileManager.default.fileExists(atPath: url.path) else { continue }
            let bundleID = data["bundle-identifier"] as? String ?? Bundle(url: url)?.bundleIdentifier
            let name = data["file-label"] as? String ?? FileManager.default.displayName(atPath: url.path)
            apps.append((url, bundleID, name))
        }
        return apps
    }
}

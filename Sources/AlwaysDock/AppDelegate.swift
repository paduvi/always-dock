import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = DockModel()
    private let windowGuard = WindowGuard()
    private var panels: [CGDirectDisplayID: DockPanelController] = [:]
    private var statusItem: NSStatusItem?
    private var screenTimer: Timer?
    private var pointerTimer: Timer?
    private var presentationObservation: NSKeyValueObservation?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Settings.shared.hideSystemDock { SystemDock.hide() }
        setUpStatusItem()

        // `kill`/`pkill` (build.sh --install uses it) would otherwise skip applicationWillTerminate
        // and leave the system Dock hidden.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(syncPanels),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(layoutPanels), name: DockModel.didChange, object: model)
        center.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        // The system Dock hopping to another screen changes visible frames without a reliable notification.
        screenTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(syncPanels),
                                           userInfo: nil, repeats: true)
        // Entering or leaving a full-screen app switches Spaces; catch it without waiting for the timer.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(syncPanels),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil)
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncPanels() }
        }
        syncPanels()

        windowGuard.reservedAreas = { [weak self] in self?.panels.values.compactMap(\.reservedArea) ?? [] }
        if Settings.shared.reserveSpace { windowGuard.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the user without any Dock once AlwaysDock is gone.
        if Settings.shared.hideSystemDock { SystemDock.restore() }
    }

    /// One dock per screen, except the screen the system Dock is currently shown on. Around full-screen
    /// content the docks behave like the system Dock: they auto-hide on screens that a window fills, and
    /// disappear while the active app hides the Dock.
    @objc private func syncPanels() {
        let avoidFullScreen = Settings.shared.autoHideInFullScreen
        let appHidesDock = avoidFullScreen && FullScreen.appHidesDock
        let fullScreen = avoidFullScreen ? FullScreen.displays() : []
        var current = Set<CGDirectDisplayID>()
        var moved = false
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            current.insert(id)
            let controller = panels[id] ?? DockPanelController(model: model)
            panels[id] = controller
            if SystemDock.occupies(screen) || appHidesDock {
                moved = controller.hide() || moved
            } else {
                moved = controller.show(on: screen, autoHide: fullScreen.contains(id)) || moved
            }
        }
        for (id, controller) in panels where !current.contains(id) {
            controller.hide()
            panels[id] = nil
        }
        if moved { windowGuard.refitSoon() }

        // Auto-hiding docks wait for the pointer at their screen edge; watch it only while there are any.
        let autoHiding = panels.values.contains { $0.autoHides }
        if autoHiding, pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(trackPointer),
                                                userInfo: nil, repeats: true)
            pointerTimer?.tolerance = 0.05
        } else if !autoHiding {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
    }

    @objc private func trackPointer() {
        let location = NSEvent.mouseLocation
        panels.values.forEach { $0.trackPointer(location) }
    }

    @objc private func layoutPanels() {
        panels.values.forEach { $0.layout() }
    }

    @objc private func settingsChanged() {
        syncPanels()
        layoutPanels()
        if Settings.shared.reserveSpace { windowGuard.start() } else { windowGuard.stop() }
        windowGuard.refitSoon()
    }

    // MARK: Menu bar item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "AlwaysDock")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = Settings.shared
        menu.removeAllItems()

        let title = NSMenuItem(title: "AlwaysDock", action: nil, keyEquivalent: "")
        title.isEnabled = false
        if let icon = NSApp.applicationIconImage.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            title.image = icon
        }
        menu.addItem(title)
        menu.addItem(.separator())

        let hideSystemDock = ClosureMenuItem("Hide System Dock") {
            settings.hideSystemDock.toggle()
            if settings.hideSystemDock { SystemDock.hide() } else { SystemDock.restore() }
        }
        hideSystemDock.state = settings.hideSystemDock ? .on : .off
        hideSystemDock.toolTip = "Use AlwaysDock on every display, including the main display and full-screen apps."
        menu.addItem(hideSystemDock)

        let autoHide = ClosureMenuItem("Auto-Hide in Full Screen") { settings.autoHideInFullScreen.toggle() }
        autoHide.state = settings.autoHideInFullScreen ? .on : .off
        autoHide.toolTip = "Like the macOS Dock: hide while a window fills the display and slide in when the pointer "
            + "pushes against the dock's edge. Stay hidden while an app such as a game hides the Dock."
        menu.addItem(autoHide)

        let waitingForPermission = settings.reserveSpace && !WindowGuard.isTrusted
        let reserveSpace = ClosureMenuItem(waitingForPermission
                                           ? "Reserve Space for Dock (waiting for Accessibility access)"
                                           : "Reserve Space for Dock") {
            settings.reserveSpace.toggle()
        }
        reserveSpace.state = waitingForPermission ? .mixed : (settings.reserveSpace ? .on : .off)
        reserveSpace.toolTip = "Keep zoomed and tiled windows clear of the dock. Requires Accessibility access."
        menu.addItem(reserveSpace)
        if waitingForPermission {
            menu.addItem(ClosureMenuItem("Open Accessibility Settings…") { WindowGuard.openSettings() })
        }

        let sizeMenu = NSMenu()
        for (name, size) in [("Small", 40.0), ("Medium", 48.0), ("Large", 64.0)] {
            let item = ClosureMenuItem(name) { settings.iconSize = size }
            item.state = settings.iconSize == size ? .on : .off
            sizeMenu.addItem(item)
        }
        menu.addItem(submenuItem("Icon Size", sizeMenu))

        let edgeMenu = NSMenu()
        for edge in DockEdge.allCases {
            let item = ClosureMenuItem(edge.title) { settings.edge = edge }
            item.state = settings.edge == edge ? .on : .off
            edgeMenu.addItem(item)
        }
        menu.addItem(submenuItem("Position", edgeMenu))

        menu.addItem(.separator())
        let launchAtLogin = ClosureMenuItem("Open at Login") { Self.toggleLaunchAtLogin() }
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // Login items need a real .app bundle (see build.sh); `swift run` has none.
        launchAtLogin.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit AlwaysDock", keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

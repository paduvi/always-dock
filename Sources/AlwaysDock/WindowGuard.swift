import AppKit
import ApplicationServices

/// A strip along a screen edge, in Cocoa screen coordinates, that windows must keep clear of.
struct ReservedArea: Equatable {
    let rect: NSRect
    let edge: DockEdge
}

/// Keeps zoomed, filled and tiled windows out of the strip AlwaysDock sits in, as the system Dock does
/// through `visibleFrame`. Third-party apps cannot change `visibleFrame`, so this watches other apps'
/// windows through the Accessibility API (it needs the Accessibility permission) and shrinks any window
/// that is resized or opened into the strip. Plain moves are left alone, so a window can still be
/// dragged behind the dock. Until access is granted, ScriptedWindowGuard does the same for apps that
/// support AppleScript.
@MainActor
final class WindowGuard: NSObject {
    var reservedAreas: () -> [ReservedArea] = { [] }
    /// Called once Accessibility access arrives after `start()` had to wait for it.
    var onAccessGranted: () -> Void = {}

    private(set) var isRunning = false
    /// Running with Accessibility access, so windows are actually being fitted.
    private(set) var isGuarding = false
    private var observers: [pid_t: AXObserver] = [:]
    private var trustTimer: Timer?
    private var pending: [AXUIElement] = []
    private var flushTimer: Timer?
    private var recentlyAdjusted: [(window: AXUIElement, date: Date)] = []

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opens Privacy & Security at the Accessibility list (titled "Device Control and Data Access" on macOS 27).
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Every query waits for the app to answer. Without a limit, one hung app would hold up the dock
        // for the default 6 seconds per query.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        if Self.isTrusted {
            attachAll()
            refitSoon()
        } else {
            // Shows the system prompt that leads to Privacy & Security → Accessibility.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            trustTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(checkTrust),
                                              userInfo: nil, repeats: true)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isGuarding = false
        trustTimer?.invalidate()
        flushTimer?.invalidate()
        pending.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
    }

    /// Re-checks every window, e.g. after the dock changed size or edge.
    func refitSoon() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refitAll), object: nil)
        perform(#selector(refitAll), with: nil, afterDelay: 0.6)
    }

    @objc private func refitAll() {
        guard isRunning, Self.isTrusted else { return }
        for pid in observers.keys {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                                &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            windows.forEach(fit)
        }
    }

    @objc private func checkTrust() {
        guard Self.isTrusted else { return }
        trustTimer?.invalidate()
        attachAll()
        refitSoon()
        onAccessGranted()
    }

    // MARK: Observing apps

    private func attachAll() {
        isGuarding = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.runningApplications.forEach(attach)
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // A freshly launched app is not ready for accessibility clients straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.attach(app) }
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(app)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isRunning, app.activationPolicy == .regular, app != .current, observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, windowCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        (attribute(kAXWindowsAttribute, of: element) as? [AXUIElement])?.forEach(watch)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Resize notifications are only reliable when registered on each window, not on the app.
    private func watch(_ window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, let observer = observers[pid] else { return }
        AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
    }

    fileprivate func handle(_ notification: String, for window: AXUIElement) {
        if notification == kAXWindowCreatedNotification { watch(window) }
        windowChanged(window)
    }

    // MARK: Fitting windows

    private func windowChanged(_ window: AXUIElement) {
        recentlyAdjusted.removeAll { $0.date.timeIntervalSinceNow < -1 }
        // Our own resize echoes back as a notification. Ignoring it keeps apps that refuse a size from looping us.
        guard !recentlyAdjusted.contains(where: { CFEqual($0.window, window) }) else { return }
        if !pending.contains(where: { CFEqual($0, window) }) { pending.append(window) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(flush),
                                          userInfo: nil, repeats: false)
    }

    @objc private func flush() {
        // Wait until the user lets go, so a live resize is not fought mid-drag.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return scheduleFlush() }
        let windows = pending
        pending.removeAll()
        windows.forEach(fit)
    }

    private func fit(_ window: AXUIElement) {
        // Every query is a round trip to the window's app, so ask for the rest only when the window
        // reaches into a strip, which most windows never do.
        guard let frame = frame(of: window), let target = Self.fitted(frame, clearOf: reservedAreas()),
              isAdjustable(window) else { return }
        setFrame(target, of: window, from: frame)
        recentlyAdjusted.append((window, Date()))
    }

    /// The frame a window shrinks to so it keeps clear of the strips, or nil when it needs no change or
    /// would be left too small. Shared with ScriptedWindowGuard, which resizes through Apple Events.
    static func fitted(_ frame: NSRect, clearOf areas: [ReservedArea]) -> NSRect? {
        var target = frame
        for area in areas where target.intersects(area.rect) {
            let strip = area.rect
            switch area.edge {
            case .bottom:
                target = NSRect(x: target.minX, y: strip.maxY, width: target.width, height: target.maxY - strip.maxY)
            case .left:
                target = NSRect(x: strip.maxX, y: target.minY, width: target.maxX - strip.maxX, height: target.height)
            case .right:
                target.size.width = strip.minX - target.minX
            }
        }
        // A window left mostly inside the strip was put there on purpose.
        guard target != frame, target.width >= 200, target.height >= 120 else { return nil }
        return target
    }

    /// Standard, resizable, on-screen windows only: no sheets, panels, minimized or full-screen windows.
    private func isAdjustable(_ window: AXUIElement) -> Bool {
        guard attribute(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole,
              attribute(kAXMinimizedAttribute, of: window) as? Bool != true,
              attribute("AXFullScreen", of: window) as? Bool != true else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // Accessibility uses a top-left origin at the primary screen's top edge; Cocoa uses bottom-left.
    private var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func frame(of window: AXUIElement) -> NSRect? {
        guard let positionValue = attribute(kAXPositionAttribute, of: window),
              let sizeValue = attribute(kAXSizeAttribute, of: window) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return NSRect(x: position.x, y: primaryScreenHeight - position.y - size.height,
                      width: size.width, height: size.height)
    }

    private func setFrame(_ target: NSRect, of window: AXUIElement, from frame: NSRect) {
        // Shrink first, then move, so the window never pokes past the screen edge in between.
        var size = target.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        // Accessibility places windows by their top-left corner, which stays put when a window gives up
        // space at the bottom. Moving it anyway would make the app lay the window out a second time.
        guard target.minX != frame.minX || target.maxY != frame.maxY else { return }
        var position = CGPoint(x: target.minX, y: primaryScreenHeight - target.maxY)
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}

private let windowCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let windowGuard = Unmanaged<WindowGuard>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Observers are scheduled on the main run loop.
    MainActor.assumeIsolated { windowGuard.handle(name, for: element) }
}

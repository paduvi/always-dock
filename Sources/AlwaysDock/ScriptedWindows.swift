import AppKit
import os

private let log = Logger(subsystem: "io.dogy.AlwaysDock", category: "ScriptedWindowGuard")

/// Reserve Space for Dock without Accessibility access, which only an administrator can grant. The window
/// list shows, with no permission at all, which windows were resized or opened into a strip, and their app
/// is asked through Apple Events to resize them. The user allows that once per app, without admin rights:
/// the running apps are asked up front, and apps opened later on resizing one of their windows, never for
/// windows that merely show up under the dock. Only apps that support AppleScript can be asked; other apps'
/// windows stay as they are.
@MainActor
final class ScriptedWindowGuard: NSObject {
    var reservedAreas: () -> [ReservedArea] = { [] }

    private(set) var isRunning = false
    private var timer: Timer?
    private var mouseUpMonitor: Any?
    /// Window sizes at the last check, by window number.
    private var sizes: [CGWindowID: CGSize] = [:]
    /// The size each window was last judged at. A window is judged again only once its size has changed and
    /// then held still for a check, so it is never fought while it animates.
    private var judged: [CGWindowID: CGSize] = [:]
    /// Windows whose size changed while on screen and has not yet held still: the user zoomed, tiled or
    /// resized them. Only these may show the user the permission prompt.
    private var resized: Set<CGWindowID> = []
    /// Whether each app can be asked: it supports AppleScript, and the user did not refuse.
    private var askable: [pid_t: Bool] = [:]
    /// Apple Events wait for the app to answer, and the first one to each app waits for the user to allow it.
    private let queue = DispatchQueue(label: "io.dogy.AlwaysDock.ScriptedWindowGuard")

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // The window list tells of no change, so it is checked once a second.
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(check), userInfo: nil,
                                     repeats: true)
        timer?.tolerance = 0.2
        // Zoom, Fill, tiling and dragging a window edge with the mouse all end with the button coming up.
        // Other apps' mouse events can be watched without any permission.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterMouseUp() }
        }
        askRunningApps()
    }

    /// Asks the user about every running app that can be asked, one after another, so that zooming goes
    /// without a prompt later. macOS does not ask again about apps already allowed or refused. Apps that are
    /// not running cannot be asked; they are asked the first time the user resizes one of their windows.
    private func askRunningApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map(\.processIdentifier).filter(isAskable)
        queue.async { [weak self] in
            for pid in pids where WindowScripting.permission(forApp: pid, askUser: true) == errAEEventNotPermitted {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.askable[pid] = false } }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        sizes.removeAll()
        judged.removeAll()
        resized.removeAll()
    }

    /// Judges every window again, e.g. after the dock changed size or edge.
    func refitSoon() {
        judged.removeAll()
    }

    /// A zoomed window takes a moment to animate to its new size: look while it does and once it is there.
    private func checkAfterMouseUp() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(check), object: nil)
        for delay in [0.3, 0.7] { perform(#selector(check), with: nil, afterDelay: delay) }
    }

    @objc private func check() {
        // Wait until the user lets go, so a window being resized by hand is not fought mid-drag.
        guard isRunning, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let areas = reservedAreas()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var current: [CGWindowID: CGSize] = [:]
        for info in windows {
            // Standard windows only: panels, menus and the docks sit at other levels.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowAlpha as String] as? Double ?? 0 > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap(CGRect.init(dictionaryRepresentation:)) else { continue }
            current[number] = bounds.size
            // A window that just appeared, e.g. on switching Spaces, was not resized by the user.
            if let last = sizes[number], last != bounds.size { resized.insert(number) }
            // A plain move keeps the size and is left alone, so a window can still be dragged behind the dock.
            guard sizes[number] == bounds.size else { continue }
            let askUser = resized.remove(number) != nil
            guard judged[number] != bounds.size else { continue }
            judged[number] = bounds.size
            guard !fillsDisplay(bounds), let target = WindowGuard.fitted(flipped(bounds), clearOf: areas),
                  isAskable(pid) else { continue }
            resize(pid: pid, window: bounds, to: flipped(target), askUser: askUser)
        }
        sizes = current
        judged = judged.filter { current[$0.key] != nil }
        resized.formIntersection(current.keys)
    }

    /// Full-screen windows cannot be resized, which the system Dock does not do either. On displays with a
    /// camera housing they usually leave the strip beside it empty.
    private func fillsDisplay(_ bounds: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.displayID else { return false }
            let display = CGDisplayBounds(id)
            return bounds.minX <= display.minX && bounds.maxX >= display.maxX
                && bounds.minY <= display.minY + screen.safeAreaInsets.top && bounds.maxY >= display.maxY
        }
    }

    /// Apps that support AppleScript give their windows a settable `bounds`. Asking any other app would only
    /// show the user a permission prompt for nothing.
    private func isAskable(_ pid: pid_t) -> Bool {
        if let known = askable[pid] { return known }
        let info = NSRunningApplication(processIdentifier: pid)?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        let enabled = info?["NSAppleScriptEnabled"]
        let scriptable = info?["OSAScriptingDefinition"] != nil || enabled as? Bool == true
            || (enabled as? String).map { ["yes", "true"].contains($0.lowercased()) } == true
        askable[pid] = scriptable
        return scriptable
    }

    private func resize(pid: pid_t, window: CGRect, to target: CGRect, askUser: Bool) {
        queue.async { [weak self] in
            do {
                try WindowScripting.setBounds(ofWindowAt: window, to: target, inApp: pid, askUser: askUser)
            } catch {
                let code = (error as NSError).code
                // The user has not been asked about this app yet, which waits until they resize one of its windows.
                guard code != Int(errAEEventWouldRequireUserConsent) else { return }
                log.error("Could not resize a window of process \(pid): \(code)")
                // The user did not allow AlwaysDock to control this app, and macOS will not ask again.
                guard code == Int(errAEEventNotPermitted) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.askable[pid] = false } }
            }
        }
    }

    /// The window list and Apple Events use a top-left origin at the primary screen's top edge; Cocoa uses
    /// bottom-left. The conversion is its own inverse.
    private func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Resizes another app's window through AppleScript's `bounds` window property ({left, top, right, bottom},
/// top-left origin), sent as raw Apple Events so that it can run off the main thread.
enum WindowScripting {
    enum Failure: Error {
        case noMatchingWindow
        case unexpectedReply
    }

    /// The window is found among the app's windows by its current frame, as the window list reports it.
    static func setBounds(ofWindowAt current: CGRect, to target: CGRect, inApp pid: pid_t, askUser: Bool) throws {
        let status = permission(forApp: pid, askUser: askUser)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }

        let app = NSAppleEventDescriptor(processIdentifier: pid)
        guard let every = withUnsafeBytes(of: Code.all, {
            NSAppleEventDescriptor(descriptorType: Code.absoluteOrdinal, data: Data($0))
        }) else { throw Failure.unexpectedReply }
        let reply = try send(Code.getData, to: app, directObject: bounds(of: windows(every)))
        guard let list = reply.paramDescriptor(forKeyword: Code.directObject)?
            .coerce(toDescriptorType: Code.list) else { throw Failure.unexpectedReply }
        guard let index = (1...max(list.numberOfItems, 1)).first(where: { index in
            guard let frame = list.atIndex(index).flatMap(rect) else { return false }
            return abs(frame.minX - current.minX) <= 2 && abs(frame.minY - current.minY) <= 2
                && abs(frame.maxX - current.maxX) <= 2 && abs(frame.maxY - current.maxY) <= 2
        }) else { throw Failure.noMatchingWindow }

        let value = NSAppleEventDescriptor.list()
        for (offset, edge) in [target.minX, target.minY, target.maxX, target.maxY].enumerated() {
            value.insert(NSAppleEventDescriptor(int32: Int32(edge.rounded())), at: offset + 1)
        }
        _ = try send(Code.setData, to: app, directObject: bounds(of: windows(NSAppleEventDescriptor(int32: Int32(index)))),
                     data: value)
    }

    /// Whether AlwaysDock may send the app Apple Events. With `askUser`, the first time shows the user the
    /// permission prompt and waits for the answer.
    static func permission(forApp pid: pid_t, askUser: Bool) -> Int {
        let app = NSAppleEventDescriptor(processIdentifier: pid)
        return withExtendedLifetime(app) {
            Int(AEDeterminePermissionToAutomateTarget(app.aeDesc, Code.wildCard, Code.wildCard, askUser))
        }
    }

    private static func send(_ eventID: AEEventID, to app: NSAppleEventDescriptor, directObject: NSAppleEventDescriptor,
                             data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: Code.coreSuite, eventID: eventID,
                                                      targetDescriptor: app, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(directObject, forKeyword: Code.directObject)
        if let data { event.setParam(data, forKeyword: Code.data) }
        // A hung app must not hold up the windows of the next one for long.
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: Code.errorNumber), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        return reply
    }

    /// `windows` of the app: every one, or the one at an index counted from the front.
    private static func windows(_ selector: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(Code.window, form: Code.absolutePosition, data: selector, in: .null())
    }

    private static func bounds(of windows: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(Code.property, form: Code.propertyID, data: NSAppleEventDescriptor(typeCode: Code.bounds), in: windows)
    }

    private static func specifier(_ desiredClass: DescType, form: DescType, data: NSAppleEventDescriptor,
                                  in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: Code.desiredClass)
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: Code.keyForm)
        record.setDescriptor(data, forKeyword: Code.keyData)
        record.setDescriptor(container, forKeyword: Code.container)
        return record.coerce(toDescriptorType: Code.objectSpecifier) ?? record
    }

    /// Apps answer with a list of four numbers; older ones with a QuickDraw rectangle {top, left, bottom, right}.
    private static func rect(_ descriptor: NSAppleEventDescriptor) -> CGRect? {
        if descriptor.descriptorType == Code.quickDrawRect, descriptor.data.count == 8 {
            let edges = descriptor.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { CGFloat($0) }
            return CGRect(x: edges[1], y: edges[0], width: edges[3] - edges[1], height: edges[2] - edges[0])
        }
        guard let list = descriptor.coerce(toDescriptorType: Code.list), list.numberOfItems == 4 else { return nil }
        let edges = (1...4).map { CGFloat(list.atIndex($0)?.int32Value ?? 0) }
        return CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
    }

    /// Four-character codes, as AppleScript dictionaries spell them.
    private enum Code {
        static let coreSuite = code("core"), getData = code("getd"), setData = code("setd")
        static let directObject = code("----"), data = code("data"), errorNumber = code("errn")
        static let window = code("cwin"), property = code("prop"), bounds = code("pbnd")
        static let desiredClass = code("want"), keyForm = code("form"), keyData = code("seld"), container = code("from")
        static let absolutePosition = code("indx"), propertyID = code("prop")
        static let absoluteOrdinal = code("abso"), all = code("all ")
        static let objectSpecifier = code("obj "), list = code("list"), quickDrawRect = code("qdrt"), wildCard = code("****")

        private static func code(_ text: String) -> FourCharCode {
            text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
        }
    }
}

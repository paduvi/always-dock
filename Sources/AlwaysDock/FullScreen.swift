import AppKit

/// Full-screen content the dock should get out of the way of, as the system Dock does.
@MainActor
enum FullScreen {
    /// What a display shows behind its dock.
    struct State {
        /// A window fills the display: a full-screen app, a slideshow, a game, a video.
        var isFull = false
        /// macOS is sliding the display from one Space to another, carrying the dock along.
        var isSwitching = false
    }

    /// Judges each display on the Space its dock is drawn with. A dock is one window on every Space, and
    /// while macOS slides between Spaces it draws the dock with one of them, offset by the slide: with the
    /// desktop leaving or coming back when a full-screen app opens or closes, or with the full-screen Space
    /// coming in when switching between full-screen apps. Windows drawn with the dock at the same offset
    /// are on its Space. `docks` holds the dock windows that are ordered in, by display.
    static func states(docks: [CGDirectDisplayID: NSWindow]) -> [CGDirectDisplayID: State] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        var content: [CGRect] = []
        var drawn: [Int: CGRect] = [:]
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap(CGRect.init(dictionaryRepresentation:)) else { continue }
            drawn[number] = bounds
            // Menus, the menu bar and the docks sit at or above the dock's level, and cover the dock already.
            if layer >= 0, layer < DockPanel.dockLevel.rawValue, info[kCGWindowAlpha as String] as? Double ?? 0 > 0 {
                content.append(bounds)
            }
        }

        var result: [CGDirectDisplayID: State] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let display = CGDisplayBounds(id)
            // On displays with a camera housing, full-screen windows usually leave the strip beside it empty.
            let topInset = screen.safeAreaInsets.top
            func fills(_ frame: CGRect, offset: CGVector) -> Bool {
                let target = display.offsetBy(dx: offset.dx, dy: offset.dy)
                return frame.minX <= target.minX && frame.maxX >= target.maxX
                    && frame.minY <= target.minY + topInset && frame.maxY >= target.maxY
            }
            guard let dock = docks[id] else {
                result[id] = State(isFull: content.contains { fills($0, offset: .zero) })
                continue
            }
            guard let shown = drawn[dock.windowNumber], shown.intersects(display) else {
                // Slid off the display in the middle of a switch. A display-sized window passing through
                // belongs to a full-screen Space, sliding in or out.
                let full = content.contains {
                    $0.width >= display.width && $0.height >= display.height - topInset && $0.intersects(display)
                }
                result[id] = State(isFull: full, isSwitching: true)
                continue
            }
            let frame = cgFrame(of: dock)
            var offset = CGVector(dx: shown.minX - frame.minX, dy: shown.minY - frame.minY)
            // The dock's own fade moves it a little, and the window list can trail it by a frame.
            let isSwitching = hypot(offset.dx, offset.dy) > 40
            if !isSwitching { offset = .zero }
            result[id] = State(isFull: content.contains { fills($0, offset: offset) }, isSwitching: isSwitching)
        }
        return result
    }

    /// The window list uses a top-left origin at the primary screen's top edge; Cocoa uses bottom-left.
    private static func cgFrame(of window: NSWindow) -> CGRect {
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

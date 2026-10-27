import AppKit

/// Full-screen content the dock should get out of the way of, as the system Dock does.
@MainActor
enum FullScreen {
    /// Displays where a window fills the whole screen: a full-screen app, a slideshow, a game, a video.
    /// Windows above the dock's level already cover it and need no help.
    static func displays() -> Set<CGDirectDisplayID> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let frames = windows.compactMap { info -> CGRect? in
            // Menus, the menu bar and the Dock's own windows sit at or above the dock's level.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < DockPanel.dockLevel.rawValue,
                  info[kCGWindowAlpha as String] as? Double ?? 0 > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        var result = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            // On displays with a camera housing, full-screen windows usually leave the strip beside it empty.
            let display = CGDisplayBounds(id)
            let topInset = screen.safeAreaInsets.top
            if frames.contains(where: { $0.minX <= display.minX && $0.maxX >= display.maxX
                    && $0.minY <= display.minY + topInset && $0.maxY >= display.maxY }) {
                result.insert(id)
            }
        }
        return result
    }

    /// Whether the active app asked for the Dock to be hidden altogether, as games and slideshows do.
    static var appHidesDock: Bool {
        NSApp.currentSystemPresentationOptions.contains(.hideDock)
    }
}

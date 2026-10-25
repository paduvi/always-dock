import Foundation

enum DockEdge: String, CaseIterable {
    case bottom, left, right

    var isVertical: Bool { self != .bottom }

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("AlwaysDock.settingsDidChange")

    private let defaults = UserDefaults.standard

    var iconSize: CGFloat {
        get {
            let value = defaults.double(forKey: "iconSize")
            return value > 0 ? value : 48
        }
        set { store(Double(newValue), forKey: "iconSize") }
    }

    /// Defaults to wherever the system Dock sits.
    var edge: DockEdge {
        get { DockEdge(rawValue: defaults.string(forKey: "edge") ?? SystemDock.orientation) ?? .bottom }
        set { store(newValue.rawValue, forKey: "edge") }
    }

    var hideSystemDock: Bool {
        get { defaults.bool(forKey: "hideSystemDock") }
        set { store(newValue, forKey: "hideSystemDock") }
    }

    /// Keep zoomed and tiled windows clear of the dock (see WindowGuard).
    var reserveSpace: Bool {
        get { defaults.bool(forKey: "reserveSpace") }
        set { store(newValue, forKey: "reserveSpace") }
    }

    private func store(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

import AppKit

/// Owns the dock window shown on one screen.
@MainActor
final class DockPanelController {
    private let model: DockModel
    private let panel = DockPanel()
    private let backdrop = BackdropView()
    private let label = LabelPanel()
    private var screen: NSScreen?
    /// The edge the dock was last laid out along. The setting can change before the next layout.
    private var edge = DockEdge.bottom
    /// Where the dock sits while it is in view.
    private var home = NSRect.zero
    /// Whether the dock belongs on its screen. While it auto-hides it can still be out of sight.
    private var isShown = false
    /// Full-screen content on the screen: stay out of sight until the pointer pushes against the dock's
    /// screen edge, like the system Dock in full screen.
    private(set) var autoHides = false
    /// Whether the dock is in view, or on its way in.
    private var isIn = false

    init(model: DockModel) {
        self.model = model
        panel.contentView = backdrop
    }

    /// The dock window while it is ordered in, in view or not.
    var window: NSWindow? { panel.isVisible ? panel : nil }

    /// `instant` is for changes made while macOS slides Spaces: the dock slides along with them, so the
    /// slide is its animation, as with the system Dock.
    func show(on screen: NSScreen, autoHide: Bool, instant: Bool = false) {
        let moved = !isShown || edge != Settings.shared.edge || self.screen?.frame != screen.frame
            || self.screen?.visibleFrame != screen.visibleFrame
        self.screen = screen
        isShown = true
        if moved { layout() }
        guard moved || autoHides != autoHide else { return }
        autoHides = autoHide
        // A dock in view that moved would visibly jump before fading, so it changes at once. Out of view,
        // it fades in at its new place.
        slide(in: !autoHide, animated: !instant && (!moved || !isIn))
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        autoHides = false
        slide(in: false, animated: false)
        panel.orderOut(nil)
    }

    /// While the dock auto-hides: bring it in when the pointer pushes against the dock's screen edge, and
    /// take it away once the pointer leaves it.
    func trackPointer(_ location: NSPoint) {
        guard autoHides, let trigger = edgeStrip else { return }
        if !isIn {
            if trigger.contains(location) { slide(in: true, animated: true) }
        } else if !trigger.union(home).insetBy(dx: -Metrics.margin * 2, dy: -Metrics.margin * 2).contains(location) {
            slide(in: false, animated: true)
        }
    }

    /// The screen's outermost points along the dock, where a pointer pushing against the edge ends up.
    private var edgeStrip: NSRect? {
        guard let screen else { return nil }
        let frame = screen.frame
        let depth: CGFloat = 2
        switch edge {
        case .bottom: return NSRect(x: home.minX, y: frame.minY, width: home.width, height: depth)
        case .left: return NSRect(x: frame.minX, y: home.minY, width: depth, height: home.height)
        case .right: return NSRect(x: frame.maxX - depth, y: home.minY, width: depth, height: home.height)
        }
    }

    /// Where the dock waits out of view: a little toward its screen edge, so that it fades in moving
    /// outward. A full slide past the edge would show up on a display that shares that edge.
    private var away: NSRect {
        let distance: CGFloat = 12
        switch edge {
        case .bottom: return home.offsetBy(dx: 0, dy: -distance)
        case .left: return home.offsetBy(dx: -distance, dy: 0)
        case .right: return home.offsetBy(dx: distance, dy: 0)
        }
    }

    /// Brings the dock into view or takes it away. Out of view it stays ordered in, transparent and
    /// click-through, so that macOS keeps carrying it along when it slides Spaces: the dock leaves with
    /// the desktop and comes back with it, as the system Dock does.
    private func slide(in visible: Bool, animated: Bool) {
        isIn = visible
        if !visible { label.orderOut(nil) }
        panel.ignoresMouseEvents = !visible
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(away, display: false)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            // Zero still goes through the animator, which stops a fade under way from undoing this change.
            context.duration = animated ? 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            panel.animator().alphaValue = visible ? 1 : 0
            panel.animator().setFrame(visible ? home : away, display: true)
        }
    }

    /// The full-length strip along the dock's screen edge that windows should keep clear of, like the
    /// space the system Dock removes from `visibleFrame`. Nil while the dock is hidden or auto-hides.
    var reservedArea: ReservedArea? {
        guard isShown, !autoHides, let screen else { return nil }
        let frame = screen.frame
        let thickness = (edge.isVertical ? home.width : home.height) + Metrics.margin * 2
        let rect: NSRect
        switch edge {
        case .bottom: rect = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left: rect = NSRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        case .right: rect = NSRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        }
        return ReservedArea(rect: rect, edge: edge)
    }

    /// Rebuilds the icons and fits the dock to its screen edge, shrinking icons when they would not fit.
    func layout() {
        // A hidden dock is laid out when it is shown again.
        guard isShown, let screen else { return }
        label.orderOut(nil)
        edge = Settings.shared.edge
        let items = model.items
        let separatorCount = zip(items, items.dropFirst()).filter { $0.isPinned && !$1.isPinned }.count

        let available = (edge.isVertical ? screen.visibleFrame.height : screen.frame.width) - Metrics.margin * 2
        let fixed = Metrics.padding * 2
            + Metrics.spacing * CGFloat(max(items.count + separatorCount - 1, 0))
            + Metrics.separator * CGFloat(separatorCount)
        let fitted = floor((available - fixed) / CGFloat(max(items.count, 1)))
        let iconSize = max(16, min(Settings.shared.iconSize, fitted))
        let crossLength = iconSize + Metrics.indicatorArea

        var cells: [NSView] = []
        for (index, item) in items.enumerated() {
            if index > 0, items[index - 1].isPinned, !item.isPinned {
                cells.append(SeparatorView(edge: edge, crossLength: crossLength))
            }
            let view = DockItemView(item: item, model: model, edge: edge, iconSize: iconSize)
            view.onHover = { [weak self] view, hovering in self?.setLabel(for: view, visible: hovering) }
            cells.append(view)
        }

        let along = cells.reduce(Metrics.padding * 2) { total, cell in
            total + (edge.isVertical ? cell.frame.height : cell.frame.width)
        } + Metrics.spacing * CGFloat(max(cells.count - 1, 0))
        let cross = crossLength + Metrics.padding * 2
        let size = edge.isVertical ? NSSize(width: cross, height: along) : NSSize(width: along, height: cross)

        let container = backdrop.contentView
        container.subviews.forEach { $0.removeFromSuperview() }
        var offset = Metrics.padding
        for cell in cells {
            if edge.isVertical {
                // Top to bottom, like the system Dock.
                cell.setFrameOrigin(NSPoint(x: Metrics.padding, y: size.height - offset - cell.frame.height))
                offset += cell.frame.height + Metrics.spacing
            } else {
                cell.setFrameOrigin(NSPoint(x: offset, y: Metrics.padding))
                offset += cell.frame.width + Metrics.spacing
            }
            container.addSubview(cell)
        }

        let origin: NSPoint
        switch edge {
        case .bottom:
            origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + Metrics.margin)
        case .left:
            origin = NSPoint(x: screen.frame.minX + Metrics.margin, y: screen.visibleFrame.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: screen.frame.maxX - Metrics.margin - size.width,
                             y: screen.visibleFrame.midY - size.height / 2)
        }
        backdrop.cornerRadius = cross * 0.36
        home = NSRect(origin: origin, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(isIn ? home : away, display: true)
        }
        panel.invalidateShadow()
    }

    private func setLabel(for view: DockItemView, visible: Bool) {
        guard visible, let window = view.window else {
            label.orderOut(nil)
            return
        }
        let itemRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        label.show(view.item.name, item: itemRect, dock: home, edge: edge)
    }
}

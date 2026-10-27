import AppKit

/// Owns the dock window shown on one screen.
@MainActor
final class DockPanelController {
    private let model: DockModel
    private let panel = DockPanel()
    private let backdrop = BackdropView()
    private let label = LabelPanel()
    private var screen: NSScreen?
    /// Whether the dock belongs on its screen. While it auto-hides it can still be out of sight.
    private var isShown = false
    /// Full-screen content on the screen: stay out of sight until the pointer pushes against the dock's
    /// screen edge, like the system Dock in full screen.
    private(set) var autoHides = false

    init(model: DockModel) {
        self.model = model
        panel.contentView = backdrop
    }

    /// Returns whether the dock was (re)placed, i.e. its reserved area may have changed.
    @discardableResult
    func show(on screen: NSScreen, autoHide: Bool) -> Bool {
        let needsLayout = !isShown || autoHides != autoHide || self.screen?.frame != screen.frame
            || self.screen?.visibleFrame != screen.visibleFrame
        self.screen = screen
        guard needsLayout else { return false }
        isShown = true
        autoHides = autoHide
        layout()
        if autoHide { conceal() } else { panel.orderFrontRegardless() }
        return true
    }

    /// Returns whether the dock was showing before.
    @discardableResult
    func hide() -> Bool {
        let wasShown = isShown
        isShown = false
        autoHides = false
        conceal()
        return wasShown
    }

    /// While the dock auto-hides: bring it in when the pointer pushes against the dock's screen edge, and
    /// take it away once the pointer leaves it.
    func trackPointer(_ location: NSPoint) {
        guard autoHides, let trigger = edgeStrip else { return }
        let keep = trigger.union(panel.frame).insetBy(dx: -Metrics.margin * 2, dy: -Metrics.margin * 2)
        if !panel.isVisible {
            if trigger.contains(location) { panel.orderFrontRegardless() }
        } else if !keep.contains(location) {
            conceal()
        }
    }

    /// The screen's outermost points along the dock, where a pointer pushing against the edge ends up.
    private var edgeStrip: NSRect? {
        guard let screen else { return nil }
        let frame = screen.frame
        let dock = panel.frame
        let depth: CGFloat = 2
        switch Settings.shared.edge {
        case .bottom: return NSRect(x: dock.minX, y: frame.minY, width: dock.width, height: depth)
        case .left: return NSRect(x: frame.minX, y: dock.minY, width: depth, height: dock.height)
        case .right: return NSRect(x: frame.maxX - depth, y: dock.minY, width: depth, height: dock.height)
        }
    }

    private func conceal() {
        panel.orderOut(nil)
        label.orderOut(nil)
    }

    /// The full-length strip along the dock's screen edge that windows should keep clear of, like the
    /// space the system Dock removes from `visibleFrame`. Nil while the dock is hidden or auto-hides.
    var reservedArea: NSRect? {
        guard isShown, !autoHides, let screen else { return nil }
        let frame = screen.frame
        let edge = Settings.shared.edge
        let thickness = (edge.isVertical ? panel.frame.width : panel.frame.height) + Metrics.margin * 2
        switch edge {
        case .bottom: return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left: return NSRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        case .right: return NSRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        }
    }

    /// Rebuilds the icons and fits the dock to its screen edge, shrinking icons when they would not fit.
    func layout() {
        guard let screen else { return }
        label.orderOut(nil)
        let edge = Settings.shared.edge
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
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func setLabel(for view: DockItemView, visible: Bool) {
        guard visible, let window = view.window else {
            label.orderOut(nil)
            return
        }
        let itemRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        label.show(view.item.name, item: itemRect, dock: panel.frame, edge: Settings.shared.edge)
    }
}

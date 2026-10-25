import AppKit

enum Metrics {
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 4
    /// Strip beside each icon, on the screen-edge side, holding the running indicator.
    static let indicatorArea: CGFloat = 6
    static let separator: CGFloat = 13
    /// Gap between the dock and the screen edge.
    static let margin: CGFloat = 4
}

/// Borderless panel that never takes focus and shows on every Space, full-screen apps included.
class DockPanel: NSPanel {
    static let dockLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = Self.dockLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The app-name bubble shown next to the hovered icon.
final class LabelPanel: DockPanel {
    private let backdrop = BackdropView()
    private let field = NSTextField(labelWithString: "")

    override init() {
        super.init()
        ignoresMouseEvents = true
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        backdrop.contentView.addSubview(field)
        contentView = backdrop
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, item: NSRect, dock: NSRect, edge: DockEdge) {
        field.stringValue = text
        field.sizeToFit()
        let size = NSSize(width: ceil(field.frame.width) + 22, height: ceil(field.frame.height) + 10)
        field.setFrameOrigin(NSPoint(x: (size.width - field.frame.width) / 2,
                                     y: (size.height - field.frame.height) / 2))
        backdrop.cornerRadius = size.height / 2

        let gap: CGFloat = 6
        let origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: item.midX - size.width / 2, y: dock.maxY + gap)
        case .left: origin = NSPoint(x: dock.maxX + gap, y: item.midY - size.height / 2)
        case .right: origin = NSPoint(x: dock.minX - gap - size.width, y: item.midY - size.height / 2)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }
}

/// Rounded translucent backdrop: Liquid Glass on macOS 26+, vibrancy on older systems.
final class BackdropView: NSView {
    let contentView = NSView()
    private let effectView: NSView

    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = contentView
            effectView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.addSubview(contentView)
            effectView = effect
        }
        super.init(frame: frame)
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(effectView)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var cornerRadius: CGFloat = 0 {
        didSet {
            if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            } else {
                effectView.layer?.cornerRadius = cornerRadius
            }
        }
    }
}

/// One app tile: icon plus running indicator; handles click, context menu and file drops.
final class DockItemView: NSView {
    let item: DockItem
    var onHover: ((DockItemView, Bool) -> Void)?

    private let model: DockModel
    private let edge: DockEdge
    private let iconSize: CGFloat
    private let imageView = NSImageView()
    private var isPressed = false { didSet { imageView.alphaValue = isPressed ? 0.6 : 1 } }
    private var isDropTarget = false { didSet { needsDisplay = true } }

    init(item: DockItem, model: DockModel, edge: DockEdge, iconSize: CGFloat) {
        self.item = item
        self.model = model
        self.edge = edge
        self.iconSize = iconSize
        let length = iconSize + Metrics.indicatorArea
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: edge.isVertical ? length : iconSize,
                                 height: edge.isVertical ? iconSize : length))

        imageView.image = model.icon(for: item)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = iconFrame
        addSubview(imageView)

        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var iconFrame: NSRect {
        let origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: 0, y: Metrics.indicatorArea)
        case .left: origin = NSPoint(x: Metrics.indicatorArea, y: 0)
        case .right: origin = .zero
        }
        return NSRect(origin: origin, size: NSSize(width: iconSize, height: iconSize))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: iconFrame, xRadius: iconSize * 0.22, yRadius: iconSize * 0.22).fill()
        }
        guard item.isRunning else { return }
        let half = Metrics.indicatorArea / 2
        let center: NSPoint
        switch edge {
        case .bottom: center = NSPoint(x: bounds.midX, y: half)
        case .left: center = NSPoint(x: half, y: bounds.midY)
        case .right: center = NSPoint(x: bounds.maxX - half, y: bounds.midY)
        }
        let diameter: CGFloat = 4
        NSColor.labelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { onHover?(self, false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
        } else {
            isPressed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        model.open(item)
    }

    override func rightMouseDown(with event: NSEvent) { showContextMenu(with: event) }

    private func showContextMenu(with event: NSEvent) {
        onHover?(self, false)
        let menu = NSMenu()
        let item = self.item
        let model = self.model
        let running = model.runningApp(for: item)
        if running == nil {
            menu.addItem(ClosureMenuItem("Open") { model.open(item) })
        }
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        })
        if let app = running {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(app.isHidden ? "Show" : "Hide") {
                _ = app.isHidden ? app.unhide() : app.hide()
            })
            menu.addItem(ClosureMenuItem("Quit") { _ = app.terminate() })
            let forceQuit = ClosureMenuItem("Force Quit") { _ = app.forceTerminate() }
            forceQuit.keyEquivalentModifierMask = .option
            forceQuit.isAlternate = true
            menu.addItem(forceQuit)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Drop files onto the icon to open them with this app

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        model.open(item, files: urls)
        return true
    }
}

/// Thin line between pinned apps and the other running apps.
final class SeparatorView: NSView {
    private let edge: DockEdge

    init(edge: DockEdge, crossLength: CGFloat) {
        self.edge = edge
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: edge.isVertical ? crossLength : Metrics.separator,
                                 height: edge.isVertical ? Metrics.separator : crossLength))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 6
        let line = edge.isVertical
            ? NSRect(x: inset, y: bounds.midY - 0.5, width: bounds.width - inset * 2, height: 1)
            : NSRect(x: bounds.midX - 0.5, y: inset, width: 1, height: bounds.height - inset * 2)
        NSColor.separatorColor.setFill()
        line.fill()
    }
}

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

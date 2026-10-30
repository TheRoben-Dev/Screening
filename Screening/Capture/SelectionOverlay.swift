import SwiftUI

struct FrozenScreen {
    let screen: NSScreen
    let shot: Screenshot
}

enum SelectionResult {
    case area(Screenshot)
    case window(id: CGWindowID, scale: CGFloat)
}

/// Full-screen panels showing the frozen desktop, one per display.
final class SelectionOverlay {
    private static var current: SelectionOverlay?

    static func run(mode: CaptureMode, screens: [FrozenScreen], windows: [CatalogWindow]) async -> SelectionResult? {
        await withCheckedContinuation { continuation in
            let overlay = SelectionOverlay(mode: mode, screens: screens, windows: windows) { result in
                current = nil
                continuation.resume(returning: result)
            }
            current = overlay
            overlay.show()
        }
    }

    let mode: CaptureMode
    private let windows: [CatalogWindow]
    private let completion: (SelectionResult?) -> Void
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private var hovered: CatalogWindow?
    private var isFinished = false

    private init(mode: CaptureMode, screens: [FrozenScreen], windows: [CatalogWindow],
                 completion: @escaping (SelectionResult?) -> Void) {
        self.mode = mode
        self.windows = windows
        self.completion = completion

        for frozen in screens {
            let panel = OverlayPanel(screen: frozen.screen)
            let container = NSView(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
            container.wantsLayer = true
            container.layer?.contents = frozen.shot.image
            container.layer?.contentsGravity = .resize

            let view = OverlayView(frozen: frozen, owner: self)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            panel.contentView = container

            panels.append(panel)
            views.append(view)
        }
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        for (panel, view) in zip(panels, views) {
            panel.orderFrontRegardless()
            if view.frozen.screen.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
        NSCursor.crosshair.set()
        HotKeyManager.shared.captureEscape { [weak self] in self?.finish(nil) }
        updateHover()
    }

    func updateHover() {
        guard mode == .window else { return }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        hovered = windows.first { $0.frame.contains(point) }
        for view in views {
            let origin = view.frozen.screen.cgFrame.origin
            view.selection = hovered?.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }
    }

    func focus(_ view: OverlayView) {
        guard let panel = view.window as? OverlayPanel else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        panel.makeFirstResponder(view)
    }

    func clearSelections(except keeper: OverlayView) {
        for view in views where view !== keeper { view.selection = nil }
    }

    func clickedWindow(on view: OverlayView) {
        guard let hovered else { return }
        finish(.window(id: hovered.id, scale: view.frozen.shot.scale))
    }

    func finish(_ result: SelectionResult?) {
        guard !isFinished else { return }
        isFinished = true
        HotKeyManager.shared.releaseEscape()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

private final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = false
        isOpaque = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    let frozen: FrozenScreen
    private weak var owner: SelectionOverlay?
    private var dragStart: CGPoint?

    // In the spirit of lifting a subject in Photos: the screen recedes, and what's selected
    // gets a soft luminous edge with a shimmer running around it.
    private let dim = CAShapeLayer()
    private let bloom = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let shimmer = CALayer()
    private let shimmerMask = CAShapeLayer()
    private let shimmerGradient = CAGradientLayer()
    private let badge = NSHostingView(rootView: SizeBadge(text: ""))

    var selection: CGRect? {
        didSet {
            guard selection != oldValue else { return }
            // Hovering glides between windows. Dragging has to track the pointer exactly.
            updateLayers(animated: owner?.mode == .window && oldValue != nil && selection != nil)
        }
    }

    init(frozen: FrozenScreen, owner: SelectionOverlay) {
        self.frozen = frozen
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        setUpLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks always belong to the selection, even over the size badge.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    private func setUpLayers() {
        guard let root = layer else { return }

        dim.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        dim.fillRule = .evenOdd
        root.addSublayer(dim)

        // A wide, faint band of light that spills both ways across the edge.
        bloom.fillColor = nil
        bloom.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        bloom.lineWidth = 7
        bloom.shadowColor = NSColor(calibratedRed: 0.85, green: 0.93, blue: 1, alpha: 1).cgColor
        bloom.shadowRadius = 22
        bloom.shadowOpacity = 1
        bloom.shadowOffset = .zero
        root.addSublayer(bloom)

        glow.fillColor = nil
        glow.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        glow.lineWidth = 1.5
        glow.shadowColor = NSColor.white.cgColor
        glow.shadowRadius = 12
        glow.shadowOpacity = 1
        glow.shadowOffset = .zero
        root.addSublayer(glow)

        shimmerMask.fillColor = nil
        shimmerMask.strokeColor = NSColor.white.cgColor
        shimmerMask.lineWidth = 3.5
        shimmer.mask = shimmerMask
        root.addSublayer(shimmer)

        // Two bright arcs, opposite each other, with long soft tails.
        let bright = NSColor.white.cgColor
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        shimmerGradient.type = .conic
        shimmerGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        shimmerGradient.endPoint = CGPoint(x: 0.5, y: 0)
        shimmerGradient.colors = [clear, bright, clear, clear, bright, clear, clear]
        shimmerGradient.locations = [0, 0.14, 0.3, 0.5, 0.64, 0.8, 1]
        shimmer.addSublayer(shimmerGradient)

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = CGFloat.pi * 2
            turn.duration = 2.4
            turn.repeatCount = .infinity
            shimmerGradient.add(turn, forKey: "turn")
        }

        badge.isHidden = true
        addSubview(badge)
    }

    override func layout() {
        super.layout()
        updateLayers(animated: false)
    }

    private func updateLayers(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        defer { CATransaction.commit() }

        dim.frame = bounds
        bloom.frame = bounds
        glow.frame = bounds
        shimmer.frame = bounds
        shimmerMask.frame = bounds

        let visible = selection.flatMap { $0.intersects(bounds) && $0.width >= 1 && $0.height >= 1 ? $0 : nil }
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        guard let visible else {
            dim.path = dimPath
            bloom.path = nil
            glow.path = nil
            shimmerMask.path = nil
            badge.isHidden = true
            return
        }

        let wanted: CGFloat = owner?.mode == .window ? 16 : 10
        let radius = min(wanted, min(visible.width, visible.height) / 2)
        let outline = CGPath(roundedRect: visible, cornerWidth: radius, cornerHeight: radius, transform: nil)
        dimPath.addPath(outline)
        dim.path = dimPath
        bloom.path = outline
        glow.path = outline
        shimmerMask.path = outline

        let side = hypot(visible.width, visible.height) + 8
        shimmerGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shimmerGradient.position = CGPoint(x: visible.midX, y: visible.midY)

        updateBadge(for: visible)
    }

    private func updateBadge(for selection: CGRect) {
        guard owner?.mode == .area else {
            badge.isHidden = true
            return
        }
        let scale = frozen.shot.scale
        badge.rootView = SizeBadge(text: "\(Int(selection.width * scale)) × \(Int(selection.height * scale))")
        let size = badge.fittingSize
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + 8)
        if origin.y + size.height > bounds.maxY { origin.y = selection.maxY - size.height - 8 }
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
        badge.frame = CGRect(origin: origin, size: size)
        badge.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.focus(self)
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        owner?.updateHover()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.focus(self)
        guard owner?.mode == .area else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        owner?.clearSelections(except: self)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y)
        ).intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if owner?.mode == .window {
            owner?.clickedWindow(on: self)
            return
        }
        defer { dragStart = nil }
        guard dragStart != nil, let selection else { return }
        // A stray click is not a selection, keep waiting for a real drag.
        guard selection.width >= 4, selection.height >= 4 else {
            self.selection = nil
            return
        }
        let scale = frozen.shot.scale
        let pixels = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                            width: selection.width * scale, height: selection.height * scale).integral
        guard let image = frozen.shot.image.cropping(to: pixels) else {
            owner?.finish(nil)
            return
        }
        let screen = frozen.screen.frame
        let rect = CGRect(x: screen.minX + selection.minX, y: screen.maxY - selection.maxY,
                          width: selection.width, height: selection.height)
        let backdrop = Backdrop(image: frozen.shot.image, frame: screen, scale: scale)
        owner?.finish(.area(Screenshot(image: image, scale: scale, screenRect: rect, backdrop: backdrop)))
    }

    override func rightMouseDown(with event: NSEvent) { owner?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.finish(nil) } // Escape
    }
}

private struct SizeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
            .fixedSize()
    }
}

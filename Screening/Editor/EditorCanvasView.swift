import AppKit
import SwiftUI

/// Frosted Liquid Glass showing whatever is behind the window. The clear style is the only
/// one that keeps the colors behind it: the regular glass and the materials go nearly opaque.
struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .clear
        view.cornerRadius = 0 // The window clips its own corners.
        // Evens out what's behind: keeps bright windows from glaring and gives the shadow a midtone to land on.
        view.tintColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 0.12, alpha: 0.38) : NSColor(white: 0.92, alpha: 0.30)
        }
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

struct EditorCanvas: NSViewRepresentable {
    let model: EditorModel
    let onViewCreated: (EditorCanvasView) -> Void

    func makeNSView(context: Context) -> EditorCanvasView {
        let view = EditorCanvasView(model: model)
        onViewCreated(view)
        return view
    }

    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

final class EditorCanvasView: NSView, NSTextFieldDelegate {
    private let model: EditorModel

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(last: CGPoint, didPushUndo: Bool)
        case cropNew(start: CGPoint)
        case cropMove(original: CGRect, start: CGPoint)
        case cropResize(anchor: CGPoint)
    }

    private struct SceneKey: Equatable {
        let size: CGSize
        let display: CGRect
        let shadow: Bool
    }

    private var sceneCache: (key: SceneKey, image: CGImage?)?
    private var drag: Drag?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textFontSize: CGFloat = 0
    private var textColor: AnnotationColor = .red
    private var replacingText: Annotation?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.onRedraw = { [weak self] in
            self?.needsDisplay = true
        }
        model.onToolChange = { [weak self] in
            guard let self else { return }
            finishTextEditing()
            window?.invalidateCursorRects(for: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Room for the titlebar on top and the floating toolbar below.
    private var contentArea: CGRect {
        CGRect(x: 24, y: 44, width: max(bounds.width - 48, 1), height: max(bounds.height - 44 - 88, 1))
    }

    /// Room the shadow needs around the image, in image pixels.
    private var shadowMargins: (top: CGFloat, left: CGFloat, bottom: CGFloat) {
        guard model.previewsShadow else { return (0, 0, 0) }
        let margin = ScreenshotShadow.margin
        return (margin.top * model.imageScale, margin.sides * model.imageScale, margin.bottom * model.imageScale)
    }

    private var viewScale: CGFloat {
        let display = model.displayRect
        let area = contentArea
        let shadow = shadowMargins
        return min(area.width / (display.width + shadow.left * 2),
                   area.height / (display.height + shadow.top + shadow.bottom),
                   1 / model.imageScale)
    }

    private var imageFrame: CGRect {
        let display = model.displayRect
        let scale = viewScale
        let size = CGSize(width: display.width * scale, height: display.height * scale)
        let area = contentArea
        // Centre the image and its shadow together, the shadow is heavier at the bottom.
        let shadow = shadowMargins
        let origin = CGPoint(x: area.midX - size.width / 2,
                             y: area.midY - size.height / 2 + (shadow.top - shadow.bottom) * scale / 2)
        return backingAlignedRect(CGRect(origin: origin, size: size), options: .alignAllEdgesNearest)
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let display = model.displayRect, frame = imageFrame, scale = viewScale
        return CGPoint(x: display.minX + (point.x - frame.minX) / scale,
                       y: display.minY + (point.y - frame.minY) / scale)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let display = model.displayRect, frame = imageFrame, scale = viewScale
        return CGPoint(x: frame.minX + (point.x - display.minX) * scale,
                       y: frame.minY + (point.y - display.minY) * scale)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let origin = toView(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * viewScale, height: rect.height * viewScale)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let display = model.displayRect
        return CGPoint(x: min(max(point.x, display.minX), display.maxX),
                       y: min(max(point.y, display.minY), display.maxY))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(imageFrame, cursor: cursor)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        layoutField()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageFrame, display = model.displayRect, scale = viewScale

        let shadow = shadowMargins
        let sceneRect = CGRect(x: frame.minX - shadow.left * scale, y: frame.minY - shadow.top * scale,
                               width: frame.width + (shadow.left * 2) * scale,
                               height: frame.height + (shadow.top + shadow.bottom) * scale)
        if let scene = scaledScene(size: sceneRect.size, frame: frame.offsetBy(dx: -sceneRect.minX, dy: -sceneRect.minY)) {
            cg.saveGState()
            cg.interpolationQuality = .none
            EditorRenderer.drawImage(scene, in: sceneRect, cg: cg)
            cg.restoreGState()
        }

        cg.saveGState()
        cg.clip(to: frame)
        cg.translateBy(x: frame.minX, y: frame.minY)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -display.minX, y: -display.minY)
        cg.interpolationQuality = .high

        var visible = model.annotations.filter { $0.id != model.editingTextID }
        if let draft = model.draft { visible.append(draft) }
        EditorRenderer.draw(visible, blurred: { model.blurredImage }, in: cg)
        cg.restoreGState()

        if model.tool == .select, let id = model.selectedID,
           let selected = model.annotations.first(where: { $0.id == id }) {
            drawSelection(toView(selected.bounds))
        }
        if model.tool == .crop { drawCropOverlay(frame: frame) }
    }

    /// The image and its shadow, scaled once to display size. Resampling a full-size capture
    /// on every redraw is too slow to follow a drag, and only annotations change during one.
    private func scaledScene(size: CGSize, frame: CGRect) -> CGImage? {
        let pixels = convertToBacking(CGRect(origin: .zero, size: size)).size
        let key = SceneKey(size: pixels, display: model.displayRect, shadow: model.previewsShadow)
        if let sceneCache, sceneCache.key == key { return sceneCache.image }

        let space = model.base.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard pixels.width >= 1, pixels.height >= 1,
              let cg = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cg.interpolationQuality = .high
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: pixels.width / size.width, y: -pixels.height / size.height)

        if model.previewsShadow, let backdrop = model.shadowBackdrop {
            EditorRenderer.drawImage(backdrop, in: CGRect(origin: .zero, size: size), cg: cg)
        }
        cg.saveGState()
        cg.clip(to: frame)
        let display = model.displayRect, scale = viewScale
        EditorRenderer.drawImage(model.base, in: CGRect(x: frame.minX - display.minX * scale, y: frame.minY - display.minY * scale,
                                                        width: CGFloat(model.base.width) * scale,
                                                        height: CGFloat(model.base.height) * scale), cg: cg)
        cg.restoreGState()

        let image = cg.makeImage()
        sceneCache = (key, image)
        return image
    }

    private func drawSelection(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawCropOverlay(frame: CGRect) {
        let path = NSBezierPath(rect: frame)
        guard let draft = model.draftCrop else {
            NSColor.black.withAlphaComponent(0.35).setFill()
            path.fill()
            return
        }
        let rect = toView(draft)
        path.append(NSBezierPath(rect: rect))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        path.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()

        NSColor.white.setFill()
        for corner in Self.corners(of: rect) {
            let handle = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
            NSBezierPath(roundedRect: handle, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            finishTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let raw = imagePoint(event)
        let point = clamped(raw)

        switch model.tool {
        case .select:
            let hit = model.topAnnotation(at: raw, tolerance: 6 / viewScale)
            model.selectedID = hit?.id
            if let hit, event.clickCount == 2, case .text = hit.kind {
                beginEditingText(hit)
            } else if hit != nil {
                drag = .moving(last: raw, didPushUndo: false)
            }
        case .crop:
            beginCropDrag(at: point, view: convert(event.locationInWindow, from: nil))
        case .text:
            if let hit = model.topAnnotation(at: raw, tolerance: 0), case .text = hit.kind {
                beginEditingText(hit)
            } else if model.displayRect.contains(raw) {
                beginNewText(at: raw)
            }
        case .step:
            if model.displayRect.contains(raw) { model.addStep(at: raw) }
        case .pen, .arrow, .box, .highlight, .blur:
            drag = .drawing(start: point)
        }
    }

    private func beginCropDrag(at point: CGPoint, view viewPoint: CGPoint) {
        guard let current = model.draftCrop else {
            drag = .cropNew(start: point)
            return
        }
        // Grabbing a corner pins the opposite one.
        let corners = Self.corners(of: current)
        let viewCorners = corners.map { toView($0) }
        if let index = viewCorners.firstIndex(where: { hypot($0.x - viewPoint.x, $0.y - viewPoint.y) <= 12 }) {
            drag = .cropResize(anchor: corners[(index + 2) % 4])
        } else if current.contains(point) {
            drag = .cropMove(original: current, start: point)
        } else {
            drag = .cropNew(start: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(event)
        let point = clamped(raw)

        switch drag {
        case .drawing(let start):
            model.draft = shape(from: start, to: point)
        case .moving(let last, let didPushUndo):
            guard let id = model.selectedID, let index = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            if !didPushUndo { model.pushUndo() }
            model.annotations[index].move(by: CGVector(dx: raw.x - last.x, dy: raw.y - last.y))
            drag = .moving(last: raw, didPushUndo: true)
        case .cropNew(let start):
            model.draftCrop = Self.rect(start, point)
        case .cropResize(let anchor):
            model.draftCrop = Self.rect(anchor, point)
        case .cropMove(let original, let start):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), model.fullRect.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), model.fullRect.height - moved.height)
            model.draftCrop = moved
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard case .drawing(let start) = drag, let draft = model.draft else { return }
        model.draft = nil
        // Anything shorter than this is a slipped click. A pen line can end where it began.
        var reached = [clamped(imagePoint(event))]
        if case .pen(let points) = draft.kind { reached = points }
        if reached.contains(where: { hypot($0.x - start.x, $0.y - start.y) >= 3 * model.imageScale }) {
            model.add(draft)
        }
    }

    private func shape(from start: CGPoint, to end: CGPoint) -> Annotation {
        let rect = Self.rect(start, end)
        let kind: AnnotationKind = switch model.tool {
        case .box: .box(rect)
        case .highlight: .highlight(rect)
        case .blur: .blur(rect)
        case .pen:
            if case .pen(let points) = model.draft?.kind { .pen(points + [end]) } else { .pen([start, end]) }
        default: .arrow(from: start, to: end)
        }
        return Annotation(kind: kind, color: model.color, lineWidth: model.lineWidth)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            model.deleteSelection()
            return
        case 36, 76: // Return, Enter
            if model.tool == .crop { model.applyCrop() }
            return
        case 53: // Escape
            if model.tool == .crop { model.cancelCrop() } else { model.selectedID = nil }
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let character = event.charactersIgnoringModifiers?.lowercased().first {
            if character == "s" {
                model.toggleShadow()
                return
            }
            if let tool = EditorTool.allCases.first(where: { $0.shortcut == character }) {
                model.choose(tool)
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Text

    private func beginNewText(at origin: CGPoint) {
        replacingText = nil
        startField(origin: origin, string: "", fontSize: model.fontSize, color: model.color)
    }

    private func beginEditingText(_ annotation: Annotation) {
        guard case .text(let origin, let string, let fontSize) = annotation.kind else { return }
        replacingText = annotation
        model.editingTextID = annotation.id
        startField(origin: origin, string: string, fontSize: fontSize, color: annotation.color)
    }

    private func startField(origin: CGPoint, string: String, fontSize: CGFloat, color: AnnotationColor) {
        textOrigin = origin
        textFontSize = fontSize
        textColor = color

        let field = NSTextField(string: string)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize * viewScale, weight: .semibold)
        field.textColor = color.nsColor
        field.delegate = self
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        textField = field
        model.isEditingText = true
        layoutField()
        window?.makeFirstResponder(field)
    }

    private func layoutField() {
        guard let textField else { return }
        textField.sizeToFit()
        let viewOrigin = toView(textOrigin)
        // NSTextField insets its text by 2pt, so shift to land on the rendered position.
        textField.frame = CGRect(x: viewOrigin.x - 2, y: viewOrigin.y,
                                 width: max(textField.frame.width + 12, 40), height: textField.frame.height)
    }

    func controlTextDidChange(_ notification: Notification) { layoutField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) || selector == #selector(insertNewline(_:)) {
            finishTextEditing()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishTextEditing() }

    func finishTextEditing() {
        guard let field = textField else { return }
        textField = nil // First, since removing the field re-enters through end-editing.
        let string = field.stringValue
        field.removeFromSuperview()
        model.isEditingText = false
        model.editingTextID = nil
        window?.makeFirstResponder(self)

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let original = replacingText, let index = model.annotations.firstIndex(where: { $0.id == original.id }) {
            let kind = AnnotationKind.text(origin: textOrigin, string: string, fontSize: textFontSize)
            if trimmed.isEmpty {
                model.pushUndo()
                model.annotations.remove(at: index)
            } else if kind != original.kind {
                model.pushUndo()
                model.annotations[index].kind = kind
            }
        } else if !trimmed.isEmpty {
            model.add(Annotation(kind: .text(origin: textOrigin, string: string, fontSize: textFontSize),
                                 color: textColor, lineWidth: model.lineWidth))
        }
        replacingText = nil
    }
}

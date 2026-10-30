import AppKit
import Observation

enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop, pen, arrow, box, text, step, highlight, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .pen: "Pen"
        case .arrow: "Arrow"
        case .box: "Rectangle"
        case .text: "Text"
        case .step: "Numbered Step"
        case .highlight: "Highlight"
        case .blur: "Blur"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .text: "textformat"
        case .step: "1.circle"
        case .highlight: "highlighter"
        case .blur: "drop.halffull"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .pen: "p"
        case .arrow: "a"
        case .box: "r"
        case .text: "t"
        case .step: "n"
        case .highlight: "h"
        case .blur: "b"
        }
    }
}

enum StrokeSize: CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var points: CGFloat {
        switch self {
        case .small: 2.5
        case .medium: 4
        case .large: 7
        }
    }

    var fontPoints: CGFloat {
        switch self {
        case .small: 15
        case .medium: 22
        case .large: 34
        }
    }
}

@Observable
final class EditorModel {
    let base: CGImage
    let imageScale: CGFloat

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect?
        var showsShadow: Bool
    }

    var annotations: [Annotation] = [] { didSet { redraw() } }
    var crop: CGRect? { didSet { redraw() } }
    var showsShadow: Bool { didSet { redraw() } }
    /// In-progress rectangle while the crop tool is active.
    var draftCrop: CGRect? { didSet { redraw() } }
    /// Shape under the pointer, not yet committed.
    var draft: Annotation? { didSet { redraw() } }
    var selectedID: UUID? {
        didSet {
            // Show the selection's style, so the toolbar tells the truth about what's picked.
            if let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
                penColor = selected.color
            }
            redraw()
        }
    }
    /// Hidden from the canvas while the inline text field stands in for it.
    var editingTextID: UUID? { didSet { redraw() } }
    var isEditingText = false

    private(set) var tool: EditorTool = .arrow
    private var toolBeforeCrop: EditorTool = .arrow

    private var penColor: AnnotationColor = .red
    private var markerColor: AnnotationColor = .yellow
    var size: StrokeSize = .medium

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    var canUndo = false
    var canRedo = false

    @ObservationIgnored var onRedraw: (() -> Void)?
    @ObservationIgnored var onToolChange: (() -> Void)?
    @ObservationIgnored private lazy var blurredStorage = EditorRenderer.makeBlurred(base)
    @ObservationIgnored private var backdropCache: (crop: CGRect?, image: CGImage?)?
    private let initialShadow: Bool

    init(screenshot: Screenshot, showsShadow: Bool = false) {
        base = screenshot.image
        imageScale = screenshot.scale
        self.showsShadow = showsShadow
        initialShadow = showsShadow
    }

    var blurredImage: CGImage { blurredStorage }
    var fullRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    var displayRect: CGRect { tool == .crop ? fullRect : (crop ?? fullRect) }
    var hasEdits: Bool {
        !annotations.isEmpty || crop != nil || showsShadow != initialShadow || (tool == .crop && draftCrop != crop)
    }
    /// Cropping needs the whole image in view, so the shadow steps aside for it.
    var previewsShadow: Bool { showsShadow && tool != .crop }

    /// The current image with its shadow, for the canvas to draw behind the live content.
    var shadowBackdrop: CGImage? {
        if let backdropCache, backdropCache.crop == crop { return backdropCache.image }
        let piece = crop.flatMap { base.cropping(to: $0) } ?? base
        let image = ScreenshotShadow.apply(to: piece, scale: imageScale)
        backdropCache = (crop, image)
        return image
    }

    func toggleShadow() {
        pushUndo()
        showsShadow.toggle()
    }
    var lineWidth: CGFloat { size.points * imageScale }
    var fontSize: CGFloat { size.fontPoints * imageScale }

    /// The highlighter keeps its own color, nobody wants a red marker because the last arrow was red.
    var color: AnnotationColor {
        get {
            access(keyPath: \.tool)
            return tool == .highlight ? markerColor : penColor
        }
        set {
            if tool == .highlight { markerColor = newValue } else { penColor = newValue }
            applyStyleToSelection { $0.color = newValue }
        }
    }

    var usesStyle: Bool { tool != .blur && tool != .crop }

    func setSize(_ newValue: StrokeSize) {
        size = newValue
        applyStyleToSelection { annotation in
            annotation.lineWidth = lineWidth
            if case .text(let origin, let string, _) = annotation.kind {
                annotation.kind = .text(origin: origin, string: string, fontSize: fontSize)
            }
        }
    }

    private func applyStyleToSelection(_ change: (inout Annotation) -> Void) {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo()
        change(&annotations[index])
    }

    func choose(_ newTool: EditorTool) {
        guard newTool != tool else { return }
        if tool == .crop { commitDraftCrop() }
        if newTool == .crop {
            toolBeforeCrop = tool
            draftCrop = crop
        }
        if newTool != .select { selectedID = nil }
        tool = newTool
        onToolChange?()
        redraw()
    }

    func applyCrop() { choose(toolBeforeCrop == .crop ? .select : toolBeforeCrop) }

    func resetCrop() { draftCrop = nil }

    func cancelCrop() {
        draftCrop = crop
        applyCrop()
    }

    private func commitDraftCrop() {
        let cleaned = draftCrop.flatMap { $0.width >= 2 && $0.height >= 2 ? $0.integral.intersection(fullRect) : nil }
        if cleaned != crop {
            pushUndo()
            crop = cleaned
        }
        draftCrop = nil
    }

    /// Counts from the highest step left, so deleting one never produces a duplicate.
    var nextStepNumber: Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .step(_, let number, _) = annotation.kind { return number }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    func addStep(at center: CGPoint) {
        let kind = AnnotationKind.step(center: center, number: nextStepNumber, diameter: fontSize * 1.35)
        add(Annotation(kind: kind, color: color, lineWidth: lineWidth))
    }

    func add(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
    }

    func deleteSelection() {
        guard let selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    func topAnnotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    func pushUndo() {
        undoStack.append(currentSnapshot)
        redoStack.removeAll()
        syncHistoryFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(snapshot)
    }

    private var currentSnapshot: Snapshot {
        Snapshot(annotations: annotations, crop: crop, showsShadow: showsShadow)
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        crop = snapshot.crop
        showsShadow = snapshot.showsShadow
        selectedID = nil
        if tool == .crop { draftCrop = crop }
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func render(shadowed: Bool = true) -> CGImage? {
        // Export from a closed draft state so a pending crop still counts.
        var effectiveCrop = crop
        if tool == .crop { effectiveCrop = draftCrop }
        guard let image = EditorRenderer.export(
            base: base, blurred: { self.blurredImage }, annotations: annotations, crop: effectiveCrop)
        else { return nil }
        guard shadowed else { return image }
        return showsShadow ? ScreenshotShadow.apply(to: image, scale: imageScale) : image
    }

    private func redraw() { onRedraw?() }
}

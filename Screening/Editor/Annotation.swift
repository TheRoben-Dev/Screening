import AppKit
import CoreImage

enum AnnotationKind: Equatable {
    case arrow(from: CGPoint, to: CGPoint)
    case box(CGRect)
    case highlight(CGRect)
    case blur(CGRect)
    case text(origin: CGPoint, string: String, fontSize: CGFloat)
    case pen([CGPoint])
    case step(center: CGPoint, number: Int, diameter: CGFloat)
}

enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, black, white

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .black: .black
        case .white: .white
        }
    }
}

/// All geometry is in image pixels with a top-left origin.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    var color: AnnotationColor
    var lineWidth: CGFloat

    init(kind: AnnotationKind, color: AnnotationColor, lineWidth: CGFloat) {
        id = UUID()
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    var bounds: CGRect {
        switch kind {
        case .arrow(let from, let to):
            CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                   width: abs(from.x - to.x), height: abs(from.y - to.y))
                .insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case .box(let rect), .highlight(let rect), .blur(let rect):
            rect
        case .text(let origin, let string, let fontSize):
            CGRect(origin: origin, size: EditorRenderer.textAttributed(string, color: color, fontSize: fontSize).size())
        case .pen(let points):
            Self.boundingBox(points).insetBy(dx: -lineWidth, dy: -lineWidth)
        case .step(let center, _, let diameter):
            CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if case .arrow(let from, let to) = kind {
            return Self.distance(from: point, toSegment: from, to) <= max(lineWidth, tolerance)
        }
        if case .pen(let points) = kind {
            return zip(points, points.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= max(lineWidth, tolerance)
            }
        }
        return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    mutating func move(by delta: CGVector) {
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.dx, y: point.y + delta.dy) }
        switch kind {
        case .arrow(let from, let to):
            kind = .arrow(from: shifted(from), to: shifted(to))
        case .box(let rect):
            kind = .box(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .highlight(let rect):
            kind = .highlight(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .blur(let rect):
            kind = .blur(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .text(let origin, let string, let fontSize):
            kind = .text(origin: shifted(origin), string: string, fontSize: fontSize)
        case .pen(let points):
            kind = .pen(points.map(shifted))
        case .step(let center, let number, let diameter):
            kind = .step(center: shifted(center), number: number, diameter: diameter)
        }
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// One drawing path for the canvas and the export, so what you see is what gets saved.
enum EditorRenderer {
    /// Expects a y-down context whose units are image pixels.
    static func draw(base: CGImage, blurred: () -> CGImage, annotations: [Annotation], in cg: CGContext) {
        drawImage(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), cg: cg)
        draw(annotations, blurred: blurred, in: cg)
    }

    static func draw(_ annotations: [Annotation], blurred: () -> CGImage, in cg: CGContext) {
        for annotation in annotations {
            draw(annotation, blurred: blurred, in: cg)
        }
    }

    private static func draw(_ annotation: Annotation, blurred: () -> CGImage, in cg: CGContext) {
        let color = annotation.color.nsColor
        cg.saveGState()
        defer { cg.restoreGState() }

        switch annotation.kind {
        case .arrow(let from, let to):
            guard let path = arrowPath(from: from, to: to, width: annotation.lineWidth) else { return }
            cg.setFillColor(color.cgColor)
            cg.addPath(path)
            cg.fillPath()

        case .box(let rect):
            let radius = annotation.lineWidth * 1.5
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(annotation.lineWidth)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.strokePath()

        case .highlight(let rect):
            cg.setFillColor(color.withAlphaComponent(0.4).cgColor)
            cg.fill(rect)

        case .blur(let rect):
            let image = blurred()
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let clipped = rect.integral.intersection(bounds)
            guard !clipped.isEmpty, let piece = image.cropping(to: clipped) else { return }
            drawImage(piece, in: clipped, cg: cg)

        case .text(let origin, let string, let fontSize):
            textAttributed(string, color: annotation.color, fontSize: fontSize).draw(at: origin)

        case .pen(let points):
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(annotation.lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(penPath(points))
            cg.strokePath()

        case .step(let center, let number, let diameter):
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            cg.setFillColor(color.cgColor)
            cg.fillEllipse(in: circle)
            let usesDarkText = annotation.color == .yellow || annotation.color == .white
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: diameter * 0.58, weight: .bold),
                .foregroundColor: usesDarkText ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        }
    }

    static func textAttributed(_ string: String, color: AnnotationColor, fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color.nsColor,
        ])
    }

    /// Curves through the midpoints, which smooths out the jitter of a hand-drawn line.
    static func penPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for (control, next) in zip(points, points.dropFirst()) {
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    /// A tapered shaft into a solid head, closer to Markup's arrow than a stroked line.
    static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath? {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return nil }
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)

        let headLength = min(width * 4.5, length * 0.7)
        let headHalf = headLength * 0.55
        let neck = CGPoint(x: to.x - unit.dx * headLength * 0.8, y: to.y - unit.dy * headLength * 0.8)
        let headBase = CGPoint(x: to.x - unit.dx * headLength, y: to.y - unit.dy * headLength)

        func offset(_ point: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.dx * amount, y: point.y + normal.dy * amount)
        }

        let path = CGMutablePath()
        path.move(to: offset(from, width * 0.2))
        path.addLine(to: offset(neck, width * 0.55))
        path.addLine(to: offset(headBase, headHalf))
        path.addLine(to: to)
        path.addLine(to: offset(headBase, -headHalf))
        path.addLine(to: offset(neck, -width * 0.55))
        path.addLine(to: offset(from, -width * 0.2))
        path.closeSubpath()
        return path
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    /// Pixelates before smoothing, so the original text can't be recovered from the blur.
    static func makeBlurred(_ image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let block = max(16, CGFloat(min(image.width, image.height)) / 60)
        let output = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block])
            .applyingGaussianBlur(sigma: block / 4)
            .cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent) ?? image
    }

    static func export(base: CGImage, blurred: () -> CGImage, annotations: [Annotation], crop: CGRect?) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let target = (crop ?? full).integral.intersection(full)
        guard !target.isEmpty else { return nil }

        let space = base.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(
            data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        cg.translateBy(x: 0, y: target.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -target.minX, y: -target.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(base: base, blurred: blurred, annotations: annotations, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage()
    }
}

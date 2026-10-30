import CoreGraphics

/// Puts a screenshot on a transparent canvas with a macOS-style drop shadow.
enum ScreenshotShadow {
    /// Canvas added around the image, in points. More below since the shadow falls downward.
    static let margin = (top: 44.0, sides: 64.0, bottom: 88.0)

    static func apply(to image: CGImage, scale: CGFloat) -> CGImage? {
        let left = margin.sides * scale
        let top = margin.top * scale
        let bottom = margin.bottom * scale
        let width = CGFloat(image.width) + left * 2
        let height = CGFloat(image.height) + top + bottom

        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // The shadow takes its shape from the image's alpha, so it follows the rounded corners.
        // Nested layers cast both shadows from one draw, which keeps the corners' edge pixels clean.
        cg.setShadow(offset: CGSize(width: 0, height: -22 * scale), blur: 56 * scale,
                     color: CGColor(gray: 0, alpha: 0.42))
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setShadow(offset: .zero, blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.30))
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.draw(image, in: CGRect(x: left, y: bottom, width: CGFloat(image.width), height: CGFloat(image.height)))
        cg.endTransparencyLayer()
        cg.endTransparencyLayer()
        return cg.makeImage()
    }
}

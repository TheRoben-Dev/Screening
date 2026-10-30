import AppKit
import SwiftUI
import XCTest
import Carbon.HIToolbox
@testable import Screening

final class ScreeningTests: XCTestCase {
    /// Left half red, right half blue, with fine stripes in a band for the blur test.
    private func makeImage(width: Int = 200, height: Int = 100) -> CGImage {
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        cg.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return cg.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let cg = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG's origin is bottom-left, x/y here are top-left like the editor's.
        cg.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2])
    }

    @MainActor func testExportCropKeepsOnlyCroppedPixels() throws {
        let base = makeImage()
        let result = try XCTUnwrap(EditorRenderer.export(
            base: base, blurred: { base }, annotations: [], crop: CGRect(x: 100, y: 10, width: 50, height: 40)))
        XCTAssertEqual(result.width, 50)
        XCTAssertEqual(result.height, 40)
        XCTAssertGreaterThan(pixel(result, x: 25, y: 20).b, 200)
    }

    @MainActor func testExportIsNotVerticallyFlipped() throws {
        let base = makeImage()
        let box = Annotation(kind: .highlight(CGRect(x: 0, y: 0, width: 200, height: 10)), color: .white, lineWidth: 1)
        let result = try XCTUnwrap(EditorRenderer.export(base: base, blurred: { base }, annotations: [box], crop: nil))
        XCTAssertGreaterThan(pixel(result, x: 20, y: 5).g, 50, "Highlight belongs at the top")
        XCTAssertEqual(pixel(result, x: 20, y: 95).g, pixel(base, x: 20, y: 95).g)
    }

    @MainActor func testBlurChangesOnlyItsRegion() throws {
        let base = makeImage()
        let blurred = EditorRenderer.makeBlurred(base)
        let region = Annotation(kind: .blur(CGRect(x: 80, y: 0, width: 40, height: 100)), color: .red, lineWidth: 1)
        let result = try XCTUnwrap(EditorRenderer.export(base: base, blurred: { blurred }, annotations: [region], crop: nil))

        let edge = pixel(result, x: 100, y: 50)
        XCTAssertTrue(edge.r > 20 && edge.b > 20, "The red/blue edge should be mixed, got \(edge)")
        XCTAssertEqual(pixel(result, x: 10, y: 50).r, pixel(base, x: 10, y: 50).r)
    }

    @MainActor func testArrowDrawsAtItsEndpoints() throws {
        let base = makeImage()
        let arrow = Annotation(kind: .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 190, y: 50)), color: .white, lineWidth: 6)
        let result = try XCTUnwrap(EditorRenderer.export(base: base, blurred: { base }, annotations: [arrow], crop: nil))
        XCTAssertEqual(pixel(result, x: 180, y: 50).g, 255)
        XCTAssertEqual(pixel(result, x: 100, y: 10).g, pixel(base, x: 100, y: 10).g)
    }

    @MainActor func testUndoRedoRestoresAnnotationsAndCrop() {
        let model = EditorModel(screenshot: Screenshot(image: makeImage(), scale: 2))
        model.add(Annotation(kind: .box(CGRect(x: 1, y: 1, width: 9, height: 9)), color: .red, lineWidth: 1))
        model.choose(.crop)
        model.draftCrop = CGRect(x: 0, y: 0, width: 50, height: 50)
        model.applyCrop()
        XCTAssertEqual(model.crop, CGRect(x: 0, y: 0, width: 50, height: 50))

        model.undo()
        XCTAssertNil(model.crop)
        XCTAssertEqual(model.annotations.count, 1)
        model.undo()
        XCTAssertTrue(model.annotations.isEmpty)
        model.redo()
        model.redo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertNotNil(model.crop)
    }

    @MainActor func testAnnotationHitTesting() {
        let arrow = Annotation(kind: .arrow(from: .zero, to: CGPoint(x: 100, y: 100)), color: .red, lineWidth: 4)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 51), tolerance: 4))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 90, y: 10), tolerance: 4))
    }

    @MainActor func testUniqueFilenameAvoidsCollisions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ImageFile.uniqueURL(in: folder, date: date)
        try Data().write(to: first)
        let second = ImageFile.uniqueURL(in: folder, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
    }

    @MainActor func testKeyComboRequiresRealModifier() {
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: UInt32(shiftKey)).hasRequiredModifier)
        XCTAssertTrue(KeyCombo(keyCode: 0, modifiers: UInt32(controlKey | shiftKey)).hasRequiredModifier)
    }

    @MainActor func testClipboardActionFollowsItsConfiguredMode() {
        XCTAssertEqual(CaptureAction.clipboardOnly.mode(clipboardMode: .window), .window)
        XCTAssertEqual(CaptureAction.area.mode(clipboardMode: .window), .area)
    }

    // MARK: Driving the real views

    /// Canvas in an offscreen window. An 800x400 pixel image at 2x fits at 400x200 points.
    @MainActor private func makeCanvas() -> (EditorModel, EditorCanvasView, NSWindow) {
        let model = EditorModel(screenshot: Screenshot(image: makeImage(width: 800, height: 400), scale: 2))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(model: model)
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        return (model, canvas, window)
    }

    /// Image pixel to the view point it's displayed at, for the layout above.
    private func viewPoint(_ pixel: CGPoint) -> CGPoint {
        let area = CGRect(x: 24, y: 44, width: 952, height: 700 - 44 - 88)
        return CGPoint(x: area.midX - 200 + pixel.x / 2, y: area.midY - 100 + pixel.y / 2)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    @MainActor private func drag(_ canvas: NSView, from: CGPoint, to: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: viewPoint(from), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: viewPoint(to), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: viewPoint(to), in: canvas))
    }

    @MainActor func testDraggingArrowLandsAtImageCoordinates() throws {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        drag(canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        guard case .arrow(let from, let to) = try XCTUnwrap(model.annotations.first).kind else {
            return XCTFail("Expected an arrow")
        }
        XCTAssertEqual(from.x, 100, accuracy: 2)
        XCTAssertEqual(from.y, 100, accuracy: 2)
        XCTAssertEqual(to.x, 300, accuracy: 2)
        XCTAssertEqual(to.y, 200, accuracy: 2)
    }

    @MainActor func testAClickWithoutDragAddsNothing() {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        drag(canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        XCTAssertTrue(model.annotations.isEmpty)
    }

    @MainActor func testCropDragExportsSelectedSize() throws {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        model.choose(.crop)
        drag(canvas, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 600, y: 300))
        model.applyCrop()
        let image = try XCTUnwrap(model.render())
        XCTAssertEqual(Double(image.width), 400, accuracy: 4)
        XCTAssertEqual(Double(image.height), 200, accuracy: 4)
    }

    @MainActor func testTextToolTypingCommitsAnnotation() throws {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        model.choose(.text)
        let at = viewPoint(CGPoint(x: 200, y: 200))
        canvas.mouseDown(with: mouse(.leftMouseDown, at: at, in: canvas))
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Hello"
        canvas.finishTextEditing()
        XCTAssertTrue(canvas.subviews.isEmpty)
        guard case .text(_, let string, _) = try XCTUnwrap(model.annotations.first).kind else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(string, "Hello")
    }

    @MainActor func testSelectMoveAndDelete() throws {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        model.add(Annotation(kind: .box(CGRect(x: 100, y: 100, width: 100, height: 100)), color: .red, lineWidth: 4))
        model.choose(.select)
        drag(canvas, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 170))
        let moved = try XCTUnwrap(model.annotations.first).bounds
        XCTAssertEqual(moved.minX, 200, accuracy: 2)
        XCTAssertEqual(moved.minY, 120, accuracy: 2)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.annotations.first).bounds.minX, 100)
        model.selectedID = model.annotations.first?.id
        model.deleteSelection()
        XCTAssertTrue(model.annotations.isEmpty)
    }

    @MainActor func testSelectionOverlayDragCropsFrozenImage() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let scale = screen.backingScaleFactor
        let image = makeImage(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        let frozen = FrozenScreen(screen: screen, shot: Screenshot(image: image, scale: scale))

        Task { @MainActor in
            let view = NSApp.windows.compactMap { $0.contentView?.subviews.first as? OverlayView }.first!
            let down = self.mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view)
            view.mouseDown(with: down)
            view.mouseDragged(with: self.mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 250), in: view))
            view.mouseUp(with: self.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 250), in: view))
        }
        let result = await SelectionOverlay.run(mode: .area, screens: [frozen], windows: [])
        guard case .area(let shot) = try XCTUnwrap(result) else { return XCTFail("Expected an area") }
        XCTAssertEqual(CGFloat(shot.image.width), 200 * scale, accuracy: 2)
        XCTAssertEqual(CGFloat(shot.image.height), 150 * scale, accuracy: 2)
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.contentView?.subviews.first is OverlayView })
    }

    @MainActor func testEverySoundOptionResolves() {
        XCTAssertNotNil(CaptureSound.scanner.sound, "ScannerSweep.wav must be bundled")
        XCTAssertNotNil(CaptureSound.instantCamera.sound, "PhotoEject.wav must be bundled")
        XCTAssertNotNil(CaptureSound.liquid.sound, "LiquidRipple.wav must be bundled")
        XCTAssertNotNil(CaptureSound.tink.sound)
        XCTAssertNil(CaptureSound.none.sound)
        XCTAssertLessThan(try XCTUnwrap(CaptureSound.scanner.sound).duration, 1)
    }

    /// Opaque rounded window on transparency, like a real capture.
    private func makeWindowImage() -> CGImage {
        let cg = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 400, height: 300), cornerWidth: 40, cornerHeight: 40, transform: nil))
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fillPath()
        return cg.makeImage()!
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let cg = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes[3]
    }

    @MainActor func testScreenshotShadowAddsTransparentCanvasAndFallsDownward() throws {
        let scale: CGFloat = 2
        let result = try XCTUnwrap(ScreenshotShadow.apply(to: makeWindowImage(), scale: scale))
        let left = Int(ScreenshotShadow.margin.sides * scale)
        let top = Int(ScreenshotShadow.margin.top * scale)
        XCTAssertEqual(result.width, 400 + left * 2)
        XCTAssertEqual(result.height, 300 + top + Int(ScreenshotShadow.margin.bottom * scale))

        XCTAssertEqual(alpha(result, x: left + 200, y: top + 150), 255, "Window stays solid")
        XCTAssertEqual(alpha(result, x: 0, y: 0), 0, "Canvas corner stays transparent")

        let below = alpha(result, x: left + 200, y: top + 300 + 40)
        let above = alpha(result, x: left + 200, y: top - 40)
        XCTAssertGreaterThan(below, 40, "Shadow should be visible under the window")
        XCTAssertGreaterThan(below, above, "Shadow should fall downward")

        let cornerNotch = alpha(result, x: left + 1, y: top + 1)
        XCTAssertLessThan(cornerNotch, 255, "The rounded corner must not be filled in")
    }

    @MainActor func testExportKeepsWindowTransparency() throws {
        let model = EditorModel(screenshot: Screenshot(image: makeWindowImage(), scale: 2), showsShadow: true)
        let result = try XCTUnwrap(model.render())
        XCTAssertEqual(alpha(result, x: 0, y: 0), 0)
    }

    @MainActor func testShadowCanBeRemovedInTheEditorAndUndone() throws {
        let opaque = makeImage(width: 400, height: 200)
        let model = EditorModel(screenshot: Screenshot(image: opaque, scale: 2), showsShadow: true)
        let margin = ScreenshotShadow.margin
        XCTAssertFalse(model.hasEdits)
        XCTAssertEqual(try XCTUnwrap(model.render()).width, 400 + Int(margin.sides * 2 * 2))

        model.toggleShadow()
        XCTAssertTrue(model.hasEdits, "Removing it must rewrite the saved file")
        let plain = try XCTUnwrap(model.render())
        XCTAssertEqual(plain.width, 400)
        XCTAssertEqual(plain.height, 200)

        model.undo()
        XCTAssertTrue(model.showsShadow)
        XCTAssertFalse(model.hasEdits)
    }

    @MainActor func testShadowWrapsTheCroppedImage() throws {
        let model = EditorModel(screenshot: Screenshot(image: makeImage(width: 400, height: 200), scale: 2), showsShadow: true)
        model.crop = CGRect(x: 0, y: 0, width: 100, height: 50)
        let margin = ScreenshotShadow.margin
        let result = try XCTUnwrap(model.render())
        XCTAssertEqual(result.width, 100 + Int(margin.sides * 2 * 2))
        XCTAssertEqual(try XCTUnwrap(model.shadowBackdrop).width, result.width)
    }

    // MARK: Toolbar

    @MainActor func testToolbarLevelFollowsWidth() {
        XCTAssertEqual(ToolbarLevel.fitting(width: 1200), .full)
        XCTAssertEqual(ToolbarLevel.fitting(width: ToolbarLevel.full.minimumWidth), .full)
        XCTAssertEqual(ToolbarLevel.fitting(width: ToolbarLevel.full.minimumWidth - 1), .compact)
        XCTAssertEqual(ToolbarLevel.fitting(width: ToolbarLevel.condensed.minimumWidth), .condensed)
        XCTAssertEqual(ToolbarLevel.fitting(width: 300), .minimal)
        XCTAssertEqual(ToolbarLevel.fitting(width: 100), .minimal)
    }

    /// The guarantee behind the levels: every layout, for every tool, fits its stated width.
    @MainActor func testEveryToolbarLayoutFitsItsMinimumWidth() {
        for level in ToolbarLevel.allCases {
            for tool in EditorTool.allCases {
                let model = EditorModel(screenshot: Screenshot(image: makeImage(), scale: 2))
                model.choose(tool)
                let content = EditorToolbarContent(model: model, level: level, onCopy: {}, onDelete: {}, onPin: {}, onDone: {})
                let width = NSHostingView(rootView: content).fittingSize.width
                print("toolbar", level, tool, width)
                XCTAssertGreaterThan(width, 0)
                XCTAssertLessThanOrEqual(width, level.minimumWidth - 16, "\(level) with \(tool) needs \(width)pt")
            }
        }
    }

    @MainActor func testSmallestToolbarFitsTheSmallestWindow() {
        XCTAssertLessThanOrEqual(ToolbarLevel.minimal.minimumWidth, 340)
    }

    // MARK: New tools

    @MainActor func testStepsNumberThemselvesAndSurviveDeletion() {
        let model = EditorModel(screenshot: Screenshot(image: makeImage(), scale: 2))
        model.addStep(at: CGPoint(x: 20, y: 20))
        model.addStep(at: CGPoint(x: 60, y: 20))
        XCTAssertEqual(model.nextStepNumber, 3)
        model.selectedID = model.annotations.first?.id
        model.deleteSelection()
        XCTAssertEqual(model.nextStepNumber, 3, "Removing step 1 must not reuse step 2's number")
    }

    @MainActor func testPenDrawsAndClosedLoopIsKept() throws {
        let (model, canvas, window) = makeCanvas()
        defer { window.close() }
        model.choose(.pen)
        let path = [(100, 100), (200, 100), (200, 200), (100, 100)].map { CGPoint(x: $0.0, y: $0.1) }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: viewPoint(path[0]), in: canvas))
        for point in path.dropFirst() {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: viewPoint(point), in: canvas))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: viewPoint(path[0]), in: canvas))
        let pen = try XCTUnwrap(model.annotations.first)
        XCTAssertTrue(pen.hitTest(CGPoint(x: 150, y: 100), tolerance: 4))
        XCTAssertFalse(pen.hitTest(CGPoint(x: 400, y: 300), tolerance: 4))
    }

    @MainActor func testRecognizesTextInAnImage() async throws {
        let width = 800, height = 160
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        NSAttributedString(string: "Screening reads text", attributes: [
            .font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: 30, y: 40))
        NSGraphicsContext.restoreGraphicsState()
        let text = try await TextRecognizer.text(in: cg.makeImage()!)
        XCTAssertTrue(text.contains("Screening reads text"), "Got: \(text)")
    }

    @MainActor func testFlashCoversTheCaptureAndStaysOutOfTheWay() throws {
        let screen = try XCTUnwrap(NSScreen.main).frame
        let rect = CGRect(x: screen.minX + 300, y: screen.minY + 300, width: 400, height: 200)
        let backdrop = Backdrop(image: makeImage(), frame: screen, scale: 2)
        let panel = CaptureFlash.play(around: rect, cornerRadius: 16, backdrop: backdrop)
        defer { CaptureFlash.cancel() }
        XCTAssertTrue(panel.frame.contains(rect))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.sharingType, .none)
    }

    /// The canvas redraws on every drag event, so a full-size image must stay smooth.
    @MainActor func testCanvasRedrawIsFastOnALargeCapture() {
        let model = EditorModel(screenshot: Screenshot(image: makeImage(width: 3456, height: 2234), scale: 2), showsShadow: true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = EditorCanvasView(model: model)
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep) // First draw builds the shadow.
        let start = Date()
        for _ in 0..<10 { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        let perFrame = Date().timeIntervalSince(start) / 10 * 1000
        print("canvas frame ms", perFrame)
        XCTAssertLessThan(perFrame, 50)
    }

    /// The shader compiles at runtime, so a mistake in it would only show up here.
    @MainActor func testRefractionShaderCompiles() {
        XCTAssertNotNil(RefractionRenderer.shared)
    }
}

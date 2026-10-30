import AppKit
@preconcurrency import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case area, window, display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Selection"
        case .window: "Window"
        case .display: "Entire Screen"
        }
    }
}

struct Screenshot {
    let image: CGImage
    /// Pixels per point, used to size the editor and its strokes.
    let scale: CGFloat
    /// Where it was on screen, for the capture animation.
    var screenRect: CGRect?
    var cornerRadius: CGFloat = 0
    var backdrop: Backdrop?
}

enum CaptureFailure: LocalizedError {
    case displayNotFound, windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The display is no longer available."
        case .windowNotFound: "That window is no longer available."
        }
    }
}

enum ScreenCapture {
    static func ensurePermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func openPrivacySettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// Returns nil when the user cancels the selection.
    static func capture(_ mode: CaptureMode) async throws -> Screenshot? {
        switch mode {
        case .display:
            return try await captureDisplayUnderCursor()
        case .area, .window:
            // Freezing the screens first means the selection can't change under the user.
            let frames = try await frozenScreens()
            let windows = mode == .window ? WindowCatalog.frontToBack() : []
            guard let selection = await SelectionOverlay.run(mode: mode, screens: frames, windows: windows) else {
                return nil
            }
            switch selection {
            case .area(let shot):
                return shot
            case .window(let id, let scale):
                var shot = try await captureWindow(id: id, scale: scale)
                let center = CGPoint(x: shot.screenRect?.midX ?? 0, y: shot.screenRect?.midY ?? 0)
                let home = frames.first { $0.screen.frame.contains(center) } ?? frames[0]
                shot.backdrop = Backdrop(image: home.shot.image, frame: home.screen.frame, scale: home.shot.scale)
                return shot
            }
        }
    }

    private static func captureDisplayUnderCursor() async throws -> Screenshot {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        guard let screen else { throw CaptureFailure.displayNotFound }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureFailure.displayNotFound
        }
        var shot = try await capture(display: display)
        shot.screenRect = screen.frame
        shot.backdrop = Backdrop(image: shot.image, frame: screen.frame, scale: shot.scale)
        return shot
    }

    private static func frozenScreens() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let shot = try await capture(display: display)
            result.append(FrozenScreen(screen: screen, shot: shot))
        }
        guard !result.isEmpty else { throw CaptureFailure.displayNotFound }
        return result
    }

    private static func capture(display: SCDisplay) async throws -> Screenshot {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = Int((info.contentRect.width * scale).rounded())
        config.height = Int((info.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Screenshot(image: image, scale: scale)
    }

    private static func captureWindow(id: CGWindowID, scale: CGFloat) async throws -> Screenshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureFailure.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        // The system's shadow squeezes the window into the same output size, softening it.
        // Capture it sharp instead, ScreenshotShadow adds the shadow around it later.
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: window.frame.minX, y: primaryHeight - window.frame.maxY,
                          width: window.frame.width, height: window.frame.height)
        return Screenshot(image: image, scale: scale, screenRect: rect, cornerRadius: 16)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Frame in the global top-left coordinates CoreGraphics windows use.
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

struct CatalogWindow {
    let id: CGWindowID
    let frame: CGRect
}

enum WindowCatalog {
    /// CGWindowList is ordered front to back, which SCShareableContent doesn't promise.
    static func frontToBack() -> [CatalogWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            return CatalogWindow(id: id, frame: frame)
        }
    }
}

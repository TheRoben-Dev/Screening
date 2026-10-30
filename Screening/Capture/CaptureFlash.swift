import SwiftUI

/// The frozen screen a capture came from. Bending light needs real pixels to bend.
struct Backdrop {
    let image: CGImage
    /// The screen's frame in global AppKit coordinates.
    let frame: CGRect
    let scale: CGFloat
}

/// Confirms a capture by disturbing the screen like the surface of a liquid around its border.
final class CaptureFlash {
    private static var current: CaptureFlash?
    private static let duration: TimeInterval = 1.25
    /// Long enough for the waves to clear, so a window opening next isn't drawn over.
    static let settleTime: Duration = .milliseconds(700)

    @discardableResult
    static func play(around rect: CGRect, cornerRadius: CGFloat, backdrop: Backdrop) -> NSPanel {
        cancel()
        let flash = CaptureFlash(rect: rect, cornerRadius: cornerRadius, backdrop: backdrop)
        current = flash
        flash.panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak flash] in
            guard let flash, current === flash else { return }
            cancel()
        }
        return flash.panel
    }

    static func cancel() {
        current?.panel.orderOut(nil)
        current = nil
    }

    private let panel: NSPanel

    private init(rect: CGRect, cornerRadius: CGFloat, backdrop: Backdrop) {
        panel = NSPanel(contentRect: backdrop.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none // Never appears in a capture taken while it plays.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(backdrop.frame, display: false)

        // The shader works top-down, in the screen's own points.
        let local = CGRect(x: rect.minX - backdrop.frame.minX, y: backdrop.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - backdrop.frame.minX, y: backdrop.frame.maxY - mouse.y)
        if !reducesMotion, let view = RefractionView(backdrop: backdrop, rect: local, origin: origin, radius: cornerRadius) {
            panel.contentView = view
        } else {
            // No moving waves, just a brief soft brightening of the capture.
            panel.contentView = NSHostingView(rootView: SoftFlash(size: backdrop.frame.size, rect: local, radius: cornerRadius))
        }
    }
}

private struct SoftFlash: View {
    let size: CGSize
    let rect: CGRect
    let radius: CGFloat
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.white.opacity(isVisible ? 0.22 : 0))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .frame(width: size.width, height: size.height)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) { isVisible = false }
            }
    }
}

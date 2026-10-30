import SwiftUI

/// Takes clicks without first activating the app, and optionally drags its window.
private final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    var movesWindow = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { movesWindow }
}

private func makeFloatingPanel(size: CGSize) -> NSPanel {
    let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

private var screenUnderMouse: NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
}

// MARK: Thumbnail

/// The small preview in the corner after a capture: click to edit, drag into any app.
final class ThumbnailPanel {
    private static var current: ThumbnailPanel?

    static func show(output: CGImage, shot: Screenshot, url: URL, showsShadow: Bool) {
        dismiss()
        let thumbnail = ThumbnailPanel(output: output, shot: shot, url: url, showsShadow: showsShadow)
        current = thumbnail
        thumbnail.present()
    }

    static func dismiss() {
        current?.panel.orderOut(nil)
        current?.dismissTask?.cancel()
        current = nil
    }

    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    private init(output: CGImage, shot: Screenshot, url: URL, showsShadow: Bool) {
        let longest: CGFloat = 220
        // Previews the shot without its shadow, which would only shrink it. The file keeps it.
        let preview = shot.image
        let ratio = min(longest / CGFloat(preview.width), longest / CGFloat(preview.height))
        let size = CGSize(width: max(CGFloat(preview.width) * ratio, 90) + 16,
                          height: max(CGFloat(preview.height) * ratio, 60) + 16)
        panel = makeFloatingPanel(size: size)
        panel.level = .statusBar
        panel.hasShadow = false

        let content = ThumbnailView(
            image: NSImage(cgImage: preview, size: .zero),
            url: url,
            onOpen: {
                Self.dismiss()
                EditorWindowController.open(shot, savedAt: url, showsShadow: showsShadow)
            },
            onPin: {
                Self.dismiss()
                PinnedImage.pin(shot.image, scale: shot.scale)
            },
            onClose: { Self.dismiss() },
            onHover: { [weak self] hovering in
                if hovering { self?.dismissTask?.cancel() } else { self?.scheduleDismiss() }
            })
        panel.contentView = FloatingHostingView(rootView: content)
    }

    private func present() {
        let visible = (screenUnderMouse ?? NSScreen.screens[0]).visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        let target = CGRect(origin: origin, size: size)
        panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, Self.current === self else { return }
            Self.dismiss()
        }
    }
}

private struct ThumbnailView: View {
    let image: NSImage
    let url: URL
    let onOpen: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture(perform: onOpen)
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .overlay(alignment: .topTrailing) {
                if isHovering {
                    HStack(spacing: 4) {
                        floatingButton("pin.fill", "Pin to Screen", action: onPin)
                        floatingButton("xmark", "Close", action: onClose)
                    }
                    .padding(6)
                }
            }
            .help("Click to edit, or drag into another app")
            .onHover { hovering in
                isHovering = hovering
                onHover(hovering)
            }
    }
}

private func floatingButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 22, height: 22)
            .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .help(title)
    .accessibilityLabel(title)
}

// MARK: Pin

/// A screenshot floating above everything, for reference while working. Drag to move.
final class PinnedImage {
    private static var pinned: [PinnedImage] = []

    static func pin(_ image: CGImage, scale: CGFloat) {
        let item = PinnedImage(image: image, scale: scale)
        pinned.append(item)
        item.panel.orderFrontRegardless()
    }

    private let panel: NSPanel

    private init(image: CGImage, scale: CGFloat) {
        let visible = (screenUnderMouse ?? NSScreen.screens[0]).visibleFrame
        let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, visible.width * 0.6 / natural.width, visible.height * 0.6 / natural.height)
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)

        panel = makeFloatingPanel(size: size)
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))

        let content = PinnedView(
            image: NSImage(cgImage: image, size: size),
            onCopy: { Task { try? await Clipboard.copy(image) } },
            onClose: { [weak self] in self?.close() })
        let hosting = FloatingHostingView(rootView: content)
        hosting.movesWindow = true
        panel.contentView = hosting
    }

    private func close() {
        panel.orderOut(nil)
        Self.pinned.removeAll { $0 === self }
    }
}

private struct PinnedView: View {
    let image: NSImage
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .overlay(alignment: .topLeading) {
                if isHovering {
                    floatingButton("xmark", "Unpin", action: onClose).padding(6)
                }
            }
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Copy", action: onCopy)
                Button("Unpin", action: onClose)
            }
    }
}

// MARK: Message

/// A brief glass message for captures that otherwise leave nothing to see.
enum GlassMessage {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = Text(text)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .padding(8)
        let hosting = NSHostingView(rootView: label)
        let size = hosting.fittingSize
        let new = makeFloatingPanel(size: size)
        new.level = .statusBar
        new.hasShadow = false
        new.ignoresMouseEvents = true
        new.contentView = hosting
        let visible = (screenUnderMouse ?? NSScreen.screens[0]).visibleFrame
        new.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 60))
        new.orderFrontRegardless()
        panel = new
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard panel === new else { return }
            new.orderOut(nil)
            panel = nil
        }
    }
}

import SwiftUI

private final class EditorWindow: NSWindow {
    var onEscape: (() -> Void)?

    /// Escape reaches here when something other than the canvas has focus, such as a toolbar button.
    override func cancelOperation(_ sender: Any?) {
        if attachedSheet == nil, let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    /// An accessory app can run without a main menu, so route the standard keys here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "w":
            performClose(nil)
            return true
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        default: return false
        }
    }
}

final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var open: [EditorWindowController] = []

    static func open(_ shot: Screenshot, savedAt url: URL, showsShadow: Bool) {
        let controller = EditorWindowController(shot: shot, url: url, showsShadow: showsShadow)
        open.append(controller)
        controller.show()
    }

    private let model: EditorModel
    private let url: URL
    private let window: EditorWindow
    private weak var canvas: EditorCanvasView?
    private var isSaving = false

    private init(shot: Screenshot, url: URL, showsShadow: Bool) {
        model = EditorModel(screenshot: shot, showsShadow: showsShadow)
        self.url = url
        window = EditorWindow(
            contentRect: Self.initialFrame(for: shot, showsShadow: showsShadow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        window.title = url.deletingPathExtension().lastPathComponent
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // Unreadable on glass over a bright background.
        window.isOpaque = false
        window.backgroundColor = .clear
        // No window behind the image: the screenshot and its controls float on their own.
        // The image draws its own shadow, and a system shadow traced from transparent content goes stale.
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: Self.minimumWidth, height: Self.minimumHeight)
        window.delegate = self
        window.onEscape = { [weak self] in self?.copyAndClose() }

        let root = ZStack(alignment: .bottom) {
            EditorCanvas(model: model) { [weak self] canvas in
                self?.canvas = canvas
                canvas.onEscape = { [weak self] in self?.copyAndClose() }
            }
                .ignoresSafeArea()
            EditorToolbar(
                model: model,
                onCopy: { [weak self] in self?.copy() },
                onDelete: { [weak self] in self?.deleteScreenshot() },
                onPin: { [weak self] in self?.pin() },
                onDone: { [weak self] in self?.done() }
            )
            .modifier(HugsImage(model: model))
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    private static let minimumWidth: CGFloat = 340
    private static let minimumHeight: CGFloat = 240
    /// Wide enough to open with the whole toolbar showing, the user can shrink it from there.
    private static let openingWidth: CGFloat = 960

    private static func initialFrame(for shot: Screenshot, showsShadow: Bool) -> CGRect {
        let margin = ScreenshotShadow.margin
        let extra = showsShadow ? CGSize(width: margin.sides * 2, height: margin.top + margin.bottom) : .zero
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let content = CGSize(width: CGFloat(shot.image.width) / shot.scale + 48 + extra.width,
                             height: CGFloat(shot.image.height) / shot.scale + 44 + 88 + extra.height)
        let width = min(max(content.width, openingWidth), visible.width * 0.9)
        // Only as tall as the image needs, so the window buttons and toolbar sit right by it.
        let height = min(max(content.height, minimumHeight), visible.height * 0.9)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    private func show() {
        AppPresence.show(window)
        window.makeFirstResponder(canvas)
    }

    private func copy() {
        canvas?.finishTextEditing()
        guard let image = model.render() else { return }
        Task { try? await Clipboard.copy(image) }
    }

    /// Escape: leave with the image as it looks right now on the clipboard. The saved file is left as it was.
    private func copyAndClose() {
        guard !isSaving, window.attachedSheet == nil else { return }
        canvas?.finishTextEditing()
        guard let image = model.render() else {
            close()
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await Clipboard.copy(image)
                close()
            } catch {
                Alerts.show(error, title: "Couldn’t copy the screenshot")
            }
        }
    }

    private func done() {
        guard !isSaving else { return }
        canvas?.finishTextEditing()
        guard model.hasEdits, let image = model.render() else {
            close()
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await Clipboard.copy(image)
                try await ImageFile.write(image, to: url)
                close()
            } catch {
                Alerts.show(error, title: "Couldn’t save the screenshot")
            }
        }
    }

    private func pin() {
        canvas?.finishTextEditing()
        // Without the shadow, the floating window casts its own.
        guard let image = model.render(shadowed: false) else { return }
        PinnedImage.pin(image, scale: model.imageScale)
    }

    private func deleteScreenshot() {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        close()
    }

    private func close() {
        window.delegate = nil
        window.close()
        Self.open.removeAll { $0 === self }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas?.finishTextEditing()
        guard model.hasEdits else {
            close()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Keep your edits?"
        alert.informativeText = "The saved screenshot stays as captured unless you keep them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.done()
            case .alertSecondButtonReturn: self?.close()
            default: break
            }
        }
        return false
    }
}

/// Keeps the toolbar just under the image rather than at the bottom of the window,
/// which can be far away when a wide image leaves room above and below it.
private struct HugsImage: ViewModifier {
    let model: EditorModel
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .padding(.bottom, max(16, model.imageBottomInset - height - 14))
    }
}

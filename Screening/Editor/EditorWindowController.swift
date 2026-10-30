import SwiftUI

private final class EditorWindow: NSWindow {
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
    private let window: NSWindow
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
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: Self.minimumWidth, height: 340)
        window.delegate = self

        let root = ZStack(alignment: .bottom) {
            FrostedBackground()
                .ignoresSafeArea()
            EditorCanvas(model: model) { [weak self] in self?.canvas = $0 }
                .ignoresSafeArea()
            EditorToolbar(
                model: model,
                onCopy: { [weak self] in self?.copy() },
                onDelete: { [weak self] in self?.deleteScreenshot() },
                onPin: { [weak self] in self?.pin() },
                onDone: { [weak self] in self?.done() }
            )
            .padding(.bottom, 20)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    private static let minimumWidth: CGFloat = 340
    /// Wide enough to open with the whole toolbar showing, the user can shrink it from there.
    private static let openingWidth: CGFloat = 960

    private static func initialFrame(for shot: Screenshot, showsShadow: Bool) -> CGRect {
        let margin = ScreenshotShadow.margin
        let extra = showsShadow ? CGSize(width: margin.sides * 2, height: margin.top + margin.bottom) : .zero
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let content = CGSize(width: CGFloat(shot.image.width) / shot.scale + 48 + extra.width,
                             height: CGFloat(shot.image.height) / shot.scale + 44 + 88 + extra.height)
        let width = min(max(content.width, openingWidth), visible.width * 0.9)
        let height = min(max(content.height, 480), visible.height * 0.9)
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

import AppKit
@preconcurrency import ScreenCaptureKit

/// Becomes a regular app while it has windows, so they get Cmd-Tab, a Dock icon and a menu bar.
enum AppPresence {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Brings a window forward. Plain activation is only a request macOS may turn down,
    /// and a capture would otherwise open its editor behind the app the user is in.
    static func show(_ window: NSWindow) {
        if !windows.contains(where: { $0 === window }) {
            windows.append(window)
            let key = ObjectIdentifier(window)
            observers[key] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { closed(window) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func closed(_ window: NSWindow) {
        windows.removeAll { $0 === window }
        if let observer = observers.removeValue(forKey: ObjectIdentifier(window)) {
            NotificationCenter.default.removeObserver(observer)
        }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Routes hotkeys and menu picks through capture, delivery and the editor.
@Observable
final class AppCoordinator {
    static let shared = AppCoordinator()

    /// Seconds left on the self-timer, shown in the menu bar.
    private(set) var countdown: Int?

    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let settings = AppSettings.shared

    func start() {
        _ = RefractionRenderer.shared // Compile the shader now, not during the first capture.
        HotKeyManager.shared.handler = { [weak self] action in
            self?.trigger(action, fromMenu: false)
        }
        HotKeyManager.shared.register(settings.hotKeys)
    }

    func trigger(_ action: CaptureAction, fromMenu: Bool) {
        guard !isBusy else { return }
        isBusy = true
        ThumbnailPanel.dismiss()
        CaptureFlash.cancel()
        Task {
            defer { isBusy = false }
            // Let the menu finish fading so it isn't in the shot.
            if fromMenu { try? await Task.sleep(for: .milliseconds(250)) }
            await run(action)
        }
    }

    /// Runs an action after a countdown, for capturing menus and hover states.
    func trigger(_ action: CaptureAction, after seconds: Int) {
        guard !isBusy, timerTask == nil else { return }
        timerTask = Task {
            for remaining in stride(from: seconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
            }
            countdown = nil
            timerTask = nil
            if !Task.isCancelled { trigger(action, fromMenu: false) }
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
    }

    func openEditor(fileAt url: URL, showsShadow: Bool) {
        guard let image = ImageFile.load(url) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        EditorWindowController.open(Screenshot(image: image, scale: scale), savedAt: url, showsShadow: showsShadow)
    }

    private func copyText(in image: CGImage) async {
        let text = (try? await TextRecognizer.text(in: image)) ?? ""
        guard !text.isEmpty else {
            NSSound.beep()
            GlassMessage.show("No text found")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        GlassMessage.show("Text copied")
    }

    private func run(_ action: CaptureAction) async {
        guard ScreenCapture.ensurePermission() else {
            Alerts.showPermissionNeeded()
            return
        }
        do {
            let mode = action.mode(clipboardMode: settings.clipboardMode)
            guard let shot = try await ScreenCapture.capture(mode) else { return }
            // Right away, like a shutter, rather than after the encoding finishes.
            settings.captureSound.play()
            var animation: Task<Void, Never>?
            if settings.playsAnimation, let rect = shot.screenRect, let backdrop = shot.backdrop {
                CaptureFlash.play(around: rect, cornerRadius: shot.cornerRadius, backdrop: backdrop)
                animation = Task { try? await Task.sleep(for: CaptureFlash.settleTime) }
            }

            if action == .text {
                await copyText(in: shot.image)
                return
            }

            let output = settings.addsShadow
                ? ScreenshotShadow.apply(to: shot.image, scale: shot.scale) ?? shot.image
                : shot.image

            try await Clipboard.copy(output)
            if action == .clipboardOnly { return }

            let url = try await ImageFile.saveNew(output, in: settings.saveFolder)
            settings.addRecent(url)
            // The waves bend a frozen picture of the screen, so let them clear before a window opens.
            if settings.afterCapture != .nothing { await animation?.value }
            switch settings.afterCapture {
            case .editor:
                // The editor gets the shot without its shadow, so the shadow stays removable.
                EditorWindowController.open(shot, savedAt: url, showsShadow: settings.addsShadow)
            case .thumbnail:
                ThumbnailPanel.show(output: output, shot: shot, url: url, showsShadow: settings.addsShadow)
            case .nothing:
                break
            }
        } catch let error as SCStreamError where error.code == .userDeclined {
            // What a stale grant looks like: preflight says yes, the capture says no.
            Alerts.showPermissionNeeded()
        } catch {
            Alerts.show(error, title: "Couldn’t take the screenshot")
        }
    }
}

enum Alerts {
    static func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    static func showPermissionNeeded() {
        let alert = NSAlert()
        alert.messageText = "Screening needs Screen Recording access"
        alert.informativeText = "Turn on Screening in Privacy & Security, then quit and reopen the app. "
            + "If it’s already on, remove it from the list with the – button and try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapture.openPrivacySettings()
        }
    }
}

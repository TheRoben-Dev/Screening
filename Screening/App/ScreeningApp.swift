import SwiftUI

@main
struct ScreeningApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(settings: .shared, coordinator: .shared)
        } label: {
            MenuBarIcon(coordinator: .shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't grab global hotkeys while hosting unit tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        AppCoordinator.shared.start()

        // `Screening --edit image.png [--shadow]` opens the editor on an existing image.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--edit"), flag + 1 < args.count {
            AppCoordinator.shared.openEditor(fileAt: URL(fileURLWithPath: args[flag + 1]), showsShadow: args.contains("--shadow"))
        }
        // `Screening --trigger display` runs a capture action without its hotkey.
        if let flag = args.firstIndex(of: "--trigger"), flag + 1 < args.count,
           let action = CaptureAction(rawValue: args[flag + 1]) {
            AppCoordinator.shared.trigger(action, fromMenu: false)
        }
        if args.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuBarIcon: View {
    let coordinator: AppCoordinator

    var body: some View {
        Image(systemName: coordinator.countdown.map { "\($0).circle.fill" } ?? "camera.viewfinder")
            .accessibilityLabel("Screening")
    }
}

private struct MenuContent: View {
    let settings: AppSettings
    let coordinator: AppCoordinator

    var body: some View {
        ForEach(CaptureAction.allCases) { action in
            Button(action.menuTitle, systemImage: action.symbol) {
                AppCoordinator.shared.trigger(action, fromMenu: true)
            }
            .keyboardShortcut(settings.hotKeys[action]?.swiftUIShortcut)
        }
        Menu("Timer") {
            if coordinator.countdown != nil {
                Button("Cancel Timer") { coordinator.cancelTimer() }
            } else {
                ForEach([CaptureAction.area, .window, .display]) { action in
                    Button("\(action.menuTitle) in 5 Seconds") { coordinator.trigger(action, after: 5) }
                }
            }
        }
        Divider()
        let recents = settings.recents.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !recents.isEmpty {
            Menu("Recent Screenshots") {
                ForEach(recents, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        // Saved files already carry any shadow, so don't add a second one.
                        coordinator.openEditor(fileAt: url, showsShadow: false)
                    }
                }
            }
        }
        Button("Open Screenshots Folder") {
            try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(settings.saveFolder)
        }
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Screening") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

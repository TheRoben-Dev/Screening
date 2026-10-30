import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared, hotKeys: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Screening Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        if let window { AppPresence.show(window) }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let hotKeys: HotKeyManager
    @State private var launchAtLogin = AppSettings.shared.launchesAtLogin

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.saveFolder.lastPathComponent)
                            .help(settings.saveFolder.path)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("After capture", selection: $settings.afterCapture) {
                    ForEach(AfterCapture.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Play capture animation", isOn: $settings.playsAnimation)
                Toggle("Add shadow to screenshots", isOn: $settings.addsShadow)
                Picker("Capture sound", selection: $settings.captureSound) {
                    ForEach(CaptureSound.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.captureSound) { _, sound in sound.play() }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        settings.launchesAtLogin = enabled
                        launchAtLogin = settings.launchesAtLogin
                    }
            } footer: {
                Text("Every capture is saved here and copied to the clipboard.")
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcuts") {
                recorderRow(.area, title: "Selection")
                recorderRow(.window, title: "Window")
                recorderRow(.display, title: "Entire Screen")
                recorderRow(.text, title: "Text")
            }

            Section {
                recorderRow(.clipboardOnly, title: "Shortcut")
                Picker("Captures", selection: $settings.clipboardMode) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Copy to Clipboard Only")
            } footer: {
                Text("Copies the capture and nothing else. No editor, no file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func recorderRow(_ action: CaptureAction, title: String) -> some View {
        LabeledContent {
            HotKeyRecorder(action: action, settings: settings)
        } label: {
            Text(title)
            if hotKeys.failed.contains(action) {
                Text("In use by another app").foregroundStyle(.red)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

private struct HotKeyRecorder: View {
    let action: CaptureAction
    let settings: AppSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 84)
            }
            .buttonStyle(.glass)

            if settings.hotKeys[action] != nil, !isRecording {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    settings.setHotKey(nil, for: action)
                    HotKeyManager.shared.register(settings.hotKeys)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .onDisappear { if isRecording { stop() } }
    }

    private var label: String {
        if isRecording { return "Type shortcut" }
        return settings.hotKeys[action]?.displayString ?? "None"
    }

    private func toggleRecording() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        isRecording = true
        HotKeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combo = KeyCombo(event: event)
            if combo.hasRequiredModifier || combo.isFunctionKey {
                settings.setHotKey(combo, for: action)
                stop()
            } else if event.keyCode == 53 { // Escape
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyManager.shared.register(settings.hotKeys)
    }
}

import Foundation
import Observation
import ServiceManagement

enum AfterCapture: String, CaseIterable, Identifiable {
    case editor, thumbnail, nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Open Editor"
        case .thumbnail: "Show Thumbnail"
        case .nothing: "Do Nothing"
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let folder = "saveFolderPath"
        static let afterCapture = "afterCapture"
        static let playsAnimation = "playsAnimation"
        static let seenActions = "seenActions"
        static let recents = "recentCaptures"
        static let captureSound = "captureSound"
        static let addsShadow = "addsShadow"
        static let clipboardMode = "clipboardMode"
        static let hotKeys = "hotKeys"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Key.folder) }
    }
    var afterCapture: AfterCapture {
        didSet { defaults.set(afterCapture.rawValue, forKey: Key.afterCapture) }
    }
    var playsAnimation: Bool {
        didSet { defaults.set(playsAnimation, forKey: Key.playsAnimation) }
    }
    private(set) var recents: [URL] {
        didSet { defaults.set(recents.map(\.path), forKey: Key.recents) }
    }
    var addsShadow: Bool {
        didSet { defaults.set(addsShadow, forKey: Key.addsShadow) }
    }
    var captureSound: CaptureSound {
        didSet { defaults.set(captureSound.rawValue, forKey: Key.captureSound) }
    }
    var clipboardMode: CaptureMode {
        didSet { defaults.set(clipboardMode.rawValue, forKey: Key.clipboardMode) }
    }
    private(set) var hotKeys: [CaptureAction: KeyCombo] {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeys) {
                defaults.set(data, forKey: Key.hotKeys)
            }
        }
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    private init() {
        defaults.register(defaults: [Key.playsAnimation: true, Key.addsShadow: true])

        if let path = defaults.string(forKey: Key.folder) {
            saveFolder = URL(fileURLWithPath: path)
        } else {
            saveFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        }
        afterCapture = defaults.string(forKey: Key.afterCapture).flatMap(AfterCapture.init(rawValue:)) ?? .editor
        playsAnimation = defaults.bool(forKey: Key.playsAnimation)
        recents = (defaults.stringArray(forKey: Key.recents) ?? []).map { URL(fileURLWithPath: $0) }
        addsShadow = defaults.bool(forKey: Key.addsShadow)
        captureSound = defaults.string(forKey: Key.captureSound).flatMap(CaptureSound.init(rawValue:)) ?? .tink
        clipboardMode = defaults.string(forKey: Key.clipboardMode).flatMap(CaptureMode.init(rawValue:)) ?? .area

        var combos: [CaptureAction: KeyCombo] = [:]
        if let data = defaults.data(forKey: Key.hotKeys),
           let saved = try? JSONDecoder().decode([CaptureAction: KeyCombo].self, from: data) {
            combos = saved
        }
        // Actions new to this user get their default. One they cleared stays cleared.
        let seen = defaults.stringArray(forKey: Key.seenActions)
            ?? (combos.isEmpty ? [] : combos.keys.map(\.rawValue))
        for action in CaptureAction.allCases where !seen.contains(action.rawValue) {
            if !combos.values.contains(action.defaultCombo) { combos[action] = action.defaultCombo }
        }
        hotKeys = combos
        defaults.set(CaptureAction.allCases.map(\.rawValue), forKey: Key.seenActions)
    }

    func addRecent(_ url: URL) {
        recents = Array(([url] + recents.filter { $0 != url }).prefix(5))
    }

    /// Assigning a combo already in use moves it, so two actions never share one.
    func setHotKey(_ combo: KeyCombo?, for action: CaptureAction) {
        var updated = hotKeys
        if let combo {
            for (other, existing) in updated where existing == combo && other != action {
                updated[other] = nil
            }
        }
        updated[action] = combo
        hotKeys = updated
    }
}

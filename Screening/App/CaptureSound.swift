import AppKit

enum CaptureSound: String, CaseIterable, Identifiable {
    case tink, liquid, scanner, instantCamera, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tink: "Tink"
        case .liquid: "Liquid"
        case .scanner: "Scanner"
        case .instantCamera: "Instant Camera"
        case .none: "None"
        }
    }

    var sound: NSSound? {
        switch self {
        case .tink: NSSound(named: "Tink")
        case .liquid: Self.bundled("LiquidRipple")
        case .scanner: Self.bundled("ScannerSweep")
        case .instantCamera: Self.bundled("PhotoEject")
        case .none: nil
        }
    }

    private static func bundled(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav")
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    private static var playing: NSSound?

    func play() {
        Self.playing?.stop()
        Self.playing = sound
        Self.playing?.play()
    }
}

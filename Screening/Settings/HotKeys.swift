import Carbon.HIToolbox
import SwiftUI

enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    case area, window, display, clipboardOnly, text

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .area: "Capture Selection"
        case .window: "Capture Window"
        case .display: "Capture Entire Screen"
        case .clipboardOnly: "Copy to Clipboard Only"
        case .text: "Capture Text"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .display: "menubar.dock.rectangle"
        case .clipboardOnly: "doc.on.clipboard"
        case .text: "text.viewfinder"
        }
    }

    var defaultCombo: KeyCombo {
        let modifiers = UInt32(controlKey | shiftKey)
        return switch self {
        case .display: KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        case .area: KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers)
        case .window: KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers)
        case .clipboardOnly: KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers)
        case .text: KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: modifiers)
        }
    }

    func mode(clipboardMode: CaptureMode) -> CaptureMode {
        switch self {
        case .area, .text: .area
        case .window: .window
        case .display: .display
        case .clipboardOnly: clipboardMode
        }
    }
}

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask, as RegisterEventHotKey expects.
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var mask = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.command) { mask |= cmdKey }
        modifiers = UInt32(mask)
    }

    /// Shift alone isn't enough for a global shortcut, it would swallow typing.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// F-keys don't interfere with typing, so they work without a modifier.
    var isFunctionKey: Bool {
        let keys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                    kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return keys.contains(Int(keyCode))
    }

    var displayString: String { modifierSymbols + KeyNames.name(for: keyCode) }

    private var modifierSymbols: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    /// Mirrors the combo in the menu. Nil for keys SwiftUI can't express, like F-keys.
    var swiftUIShortcut: KeyboardShortcut? {
        let name = KeyNames.name(for: keyCode)
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// Asks the active keyboard layout, so a Swedish keyboard shows its own labels.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            UCKeyTranslate(
                buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

private nonisolated func hotKeyCallback(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let index = Int(hotKeyID.id)
    // Carbon delivers hotkey events on the main thread.
    MainActor.assumeIsolated { HotKeyManager.shared.fire(index: index) }
    return noErr
}

/// Global shortcuts via Carbon, which unlike event taps needs no Accessibility permission.
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    var handler: ((CaptureAction) -> Void)?
    /// Combos another app already owns.
    private(set) var failed: Set<CaptureAction> = []

    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var handlerInstalled = false
    @ObservationIgnored private var escapeRef: EventHotKeyRef?
    @ObservationIgnored private var escapeHandler: (() -> Void)?
    private static let signature: OSType = 0x5343524E // 'SCRN'
    private static let escapeIndex = 100

    func register(_ combos: [CaptureAction: KeyCombo]) {
        installHandlerIfNeeded()
        unregisterAll()

        var failures: Set<CaptureAction> = []
        for (index, action) in CaptureAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failures.insert(action)
            }
        }
        failed = failures
    }

    /// While a recorder is listening, the existing shortcuts must not fire.
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    /// Claims Escape while the selection overlay is up. Key events alone aren't enough:
    /// if the overlay ever failed to get focus, the user would be stuck behind a frozen screen.
    func captureEscape(_ onEscape: @escaping () -> Void) {
        installHandlerIfNeeded()
        releaseEscape()
        escapeHandler = onEscape
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(Self.escapeIndex))
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetEventDispatcherTarget(), 0, &escapeRef)
    }

    func releaseEscape() {
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        escapeRef = nil
        escapeHandler = nil
    }

    fileprivate func fire(index: Int) {
        if index == Self.escapeIndex {
            escapeHandler?()
            return
        }
        guard CaptureAction.allCases.indices.contains(index) else { return }
        handler?(CaptureAction.allCases[index])
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }
}

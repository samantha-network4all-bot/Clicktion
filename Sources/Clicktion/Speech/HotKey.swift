import Carbon
import Cocoa

/// A key + Carbon modifier mask, with display/conversion helpers.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, …)

    /// ⌥Space — the default dictation shortcut.
    static let defaultDictation = HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKey))

    /// Human-readable form, e.g. "⌥Space" or "⌃⌘D".
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Maps AppKit modifier flags to the Carbon mask used by RegisterEventHotKey.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        if let name = specialKeys[code] { return name }
        if let letter = letterKeys[code] { return letter }
        return "Key\(code)"
    }

    private static let specialKeys: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 117: "Fwd Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let letterKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]
}

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
    let id: EventHotKeyID
    private let ref: EventHotKeyRef
    fileprivate static var callback: (() -> Void)?

    init?(keyCode: UInt32, modifiers: UInt32, hotKeyID: UInt32 = 1, handler: @escaping () -> Void) {
        Self.callback = handler
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.id = EventHotKeyID(signature: "Clck".fourCharCode, id: hotKeyID)

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else { return nil }
        self.ref = ref
        Self.installHandler()
    }

    mutating func unregister() {
        UnregisterEventHotKey(ref)
    }

    // MARK: - Callback

    private static var isHandlerInstalled = false

    private static func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, 1, &eventType, nil, nil)
    }
}

private let hotKeyHandler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
    guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if err == noErr, hotKeyID.signature == "Clck".fourCharCode {
        HotKey.callback?()
    }
    return noErr
}

private extension String {
    var fourCharCode: FourCharCode {
        utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}

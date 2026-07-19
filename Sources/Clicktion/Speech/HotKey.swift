import Carbon
import Cocoa

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

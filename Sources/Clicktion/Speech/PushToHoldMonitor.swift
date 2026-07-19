import Carbon
import CoreGraphics
import Foundation

/// Watches a key combo globally via a CGEventTap and reports press/release,
/// so the hotkey can be used push-to-hold. Requires Accessibility permission
/// (the tap gets no key events without it). Consumes the combo while held so
/// the key doesn't also reach the focused app.
final class PushToHoldMonitor {
    private let keyCode: CGKeyCode
    private let requiredFlags: CGEventFlags
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    init(keyCode: UInt32,
         carbonModifiers: UInt32,
         onPress: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.keyCode = CGKeyCode(keyCode)
        self.requiredFlags = Self.cgFlags(fromCarbon: carbonModifiers)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns false if the tap couldn't be created (usually missing Accessibility).
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PushToHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    // Runs on the main run loop.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled the tap (timeout / user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == keyCode else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            // Ignore auto-repeat while the key is held.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return isDown ? nil : Unmanaged.passUnretained(event)
            }
            guard event.flags.contains(requiredFlags) else {
                return Unmanaged.passUnretained(event)
            }
            if !isDown {
                isDown = true
                onPress()
            }
            return nil   // consume so the key doesn't type into the focused app

        case .keyUp:
            if isDown {
                isDown = false
                onRelease()
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func cgFlags(fromCarbon carbon: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }
}

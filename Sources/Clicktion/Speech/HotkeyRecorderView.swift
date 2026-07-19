import AppKit
import SwiftUI

/// A small button that records a global-hotkey combo when clicked.
struct HotkeyRecorderView: NSViewRepresentable {
    var combo: HotKeyCombo
    /// Called with a new combo once the user presses a valid shortcut.
    var onCapture: (HotKeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onCapture = onCapture
        button.combo = combo
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onCapture = onCapture
        if !nsView.isRecording { nsView.combo = combo }
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((HotKeyCombo) -> Void)?

    var combo: HotKeyCombo = .defaultDictation {
        didSet { refreshTitle() }
    }
    private(set) var isRecording = false {
        didSet { refreshTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Esc cancels recording without changing the shortcut.
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = HotKeyCombo.carbonModifiers(event.modifierFlags)
        // A global hotkey needs at least one modifier, otherwise it would
        // swallow that plain key everywhere.
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCapture?(combo)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func refreshTitle() {
        title = isRecording ? "Press shortcut…" : combo.displayString
    }
}

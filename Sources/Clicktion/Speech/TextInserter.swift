import AppKit
import ApplicationServices

enum TextInserter {
    @MainActor
    static func insert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { dict[type] = item.data(forType: type) }
            return dict
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let saved else { return }
            pasteboard.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }
        return true
    }

    /// Copies `text` to the clipboard (leaving it there), reactivates `app`, and
    /// pastes into it. Used by the Dictation Pad, where our own window is key so
    /// we must hand focus back to the target app before synthesizing ⌘V.
    /// Returns false if Accessibility isn't granted.
    @MainActor
    static func copyAndPaste(_ text: String, into app: NSRunningApplication?) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if let app, app.processIdentifier != NSRunningApplication.current.processIdentifier {
            app.activate()
        }

        // Give the target app a moment to become frontmost before pasting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            synthesizeCommandV()
        }
        return true
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

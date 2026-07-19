import AppKit

/// Small helper for the warning alerts used across the speech feature, so each
/// call site is one line instead of repeated `NSAlert` boilerplate.
enum SystemAlert {
    /// Deep links to the relevant Privacy & Security panes.
    enum PrivacyPane {
        static let microphone = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
        static let accessibility = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }

    /// Shows a warning alert. When `settingsURL` is set, offers an
    /// "Open System Settings" button that opens it; otherwise a plain "OK".
    @MainActor
    static func warn(_ title: String, _ message: String, settingsURL: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning

        if let settingsURL {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(settingsURL)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

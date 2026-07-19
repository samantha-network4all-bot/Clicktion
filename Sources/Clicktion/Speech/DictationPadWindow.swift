import AppKit
import SwiftUI

@MainActor
final class DictationPadWindow {
    static let shared = DictationPadWindow()

    private var window: NSWindow?
    private let vm = DictationPadViewModel()
    /// The app that was frontmost when the pad was opened — the paste target.
    private var previousApp: NSRunningApplication?

    private init() {}

    func show() {
        // Capture the paste target before our own window steals focus.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Route dictation segments into this pad's text (committed + live partial).
        SpeechManager.shared.onPadTranscription = { [weak self] segment in
            self?.vm.appendFinal(segment)
        }
        SpeechManager.shared.onPadPartial = { [weak self] partial in
            self?.vm.setPartial(partial)
        }
        SpeechManager.shared.onPadError = { [weak self] message in
            self?.vm.showError(message)
        }

        let view = DictationPadView(vm: vm) { [weak self] text in
            self?.copyAndPaste(text)
        }
        let controller = NSHostingController(rootView: view)

        // Roughly A4 portrait proportions.
        let win = NSWindow(contentViewController: controller)
        win.title = "Dictation Pad"
        win.setContentSize(NSSize(width: 600, height: 780))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.minSize = NSSize(width: 420, height: 400)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SpeechManager.shared.setPadDictating(false)
                SpeechManager.shared.onPadTranscription = nil
                SpeechManager.shared.onPadPartial = nil
                SpeechManager.shared.onPadError = nil
            }
        }

        window = win
    }

    private func copyAndPaste(_ text: String) {
        guard !text.isEmpty else { return }
        // Stop continuous dictation so it doesn't keep appending after we leave.
        SpeechManager.shared.setPadDictating(false)

        guard previousApp != nil else {
            // No target we can paste into — just copy so the user can paste manually.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        if !TextInserter.copyAndPaste(text, into: previousApp) {
            SystemAlert.warn(
                "Accessibility Access Required",
                """
                Clicktion needs Accessibility access to paste text into your previous app. \
                The text has been copied to the clipboard — you can paste it manually with ⌘V.

                Open System Settings → Privacy & Security → Accessibility and add Clicktion.
                """,
                settingsURL: SystemAlert.PrivacyPane.accessibility)
        }
    }
}

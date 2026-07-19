import AppKit
import SwiftUI

@MainActor
final class BrowserAgentWindow {
    static let shared = BrowserAgentWindow()

    private var window: NSWindow?
    private let vm = BrowserAgentViewModel()

    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Spoken instructions are queued on the view model; the user can keep
        // talking while the agent works.
        SpeechManager.shared.onAgentInstruction = { [weak self] instruction in
            self?.vm.submit(instruction)
        }

        let controller = NSHostingController(rootView: BrowserAgentView(vm: vm))
        let win = NSWindow(contentViewController: controller)
        win.title = "Browser Assistant"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 1100, height: 720))
        win.minSize = NSSize(width: 900, height: 560)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                SpeechManager.shared.setAgentDictating(false)
                SpeechManager.shared.onAgentInstruction = nil
                self?.vm.stop()
                self?.window = nil
            }
        }

        window = win
    }
}

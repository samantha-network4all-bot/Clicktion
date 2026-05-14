import AppKit
import SwiftUI

@MainActor
final class SkillEditorWindow {
    static let shared = SkillEditorWindow()
    private var window: NSWindow?
    private init() {}

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SkillEditorView()
        let controller = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: controller)
        win.title = "Skills"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 860, height: 580))
        win.minSize = NSSize(width: 700, height: 440)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.window = nil }
        }

        window = win
    }
}

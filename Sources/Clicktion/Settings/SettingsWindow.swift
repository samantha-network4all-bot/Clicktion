import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: SettingsView())
        controller.sizingOptions = []
        let win = NSWindow(contentViewController: controller)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 360, height: 500))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

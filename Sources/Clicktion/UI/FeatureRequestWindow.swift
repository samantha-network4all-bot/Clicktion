import AppKit
import SwiftUI

@MainActor
final class FeatureRequestWindow {
    static let shared = FeatureRequestWindow()
    private var window: NSWindow?
    private init() {}

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = FeatureRequestView { [weak self] in self?.window?.close() }
        let controller = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: controller)
        win.title = "Request Feature"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 520, height: 360))
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

import AppKit
import SwiftUI

@MainActor
final class CaptureDialogWindow {
    private var window: NSWindow?

    static let shared = CaptureDialogWindow()
    private init() {}

    func show(capture: CaptureResult) {
        // Close any existing dialog before showing a new one
        window?.close()

        let vm = CaptureDialogViewModel(capture: capture)
        let view = CaptureDialogView(vm: vm) { [weak self] jobID, captureID, skill in
            self?.window?.close()
            self?.window = nil
            ChatWindowController.shared.open(capture: capture, captureID: captureID, jobID: jobID, skill: skill)
        }

        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize

        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.title = windowTitle(for: capture)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.level = .floating
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Release our reference when the user closes the window via the
        // titlebar's red close button — keeps memory + state clean.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.window = nil }
        }

        window = win
    }

    /// "Clicktion — App — Window" if available, falls back gracefully.
    private func windowTitle(for capture: CaptureResult) -> String {
        switch (capture.appName, capture.windowTitle) {
        case let (app?, title?): return "Clicktion — \(app) — \(title)"
        case let (app?, nil):    return "Clicktion — \(app)"
        case let (nil, title?):  return "Clicktion — \(title)"
        default:                 return "Clicktion"
        }
    }
}

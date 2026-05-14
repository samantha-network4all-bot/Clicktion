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
        let view = CaptureDialogView(vm: vm) { [weak self] jobID, skill in
            self?.window?.close()
            self?.window = nil
            ChatWindowController.shared.open(capture: capture, jobID: jobID, skill: skill)
        } onCancel: { [weak self] in
            self?.window?.close()
            self?.window = nil
        }

        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize

        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}

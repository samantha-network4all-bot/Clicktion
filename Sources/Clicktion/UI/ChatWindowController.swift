import AppKit
import SwiftUI

@MainActor
final class ChatWindowController {
    static let shared = ChatWindowController()
    private init() {}

    private var windows: [String: NSWindow] = [:]

    func open(capture: CaptureResult, captureID: String?, jobID: String?, skill: Skill?) {
        let windowKey = jobID ?? UUID().uuidString

        if let existing = windows[windowKey] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = ChatViewModel(capture: capture, captureID: captureID, jobID: jobID, skill: skill)
        let view = ChatView(vm: vm)
        let controller = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: controller)
        win.setContentSize(NSSize(width: 640, height: 520))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.title = skill?.name ?? "Chat"
        win.minSize = NSSize(width: 480, height: 360)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clean up reference when window closes
        let key: String = windowKey
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windows.removeValue(forKey: key)
            }
        }

        windows[windowKey] = win
    }
}

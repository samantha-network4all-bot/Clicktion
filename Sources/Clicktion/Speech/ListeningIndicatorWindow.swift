import AppKit
import SwiftUI

final class ListeningIndicatorWindow {
    private var window: NSWindow?

    @MainActor
    func show(state: SpeechState) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = w
        }

        guard let w = window else { return }

        let hosting = NSHostingView(rootView: ListeningIndicatorView(state: state))
        hosting.frame.size = hosting.fittingSize
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let x = (screen.frame.width - w.frame.width) / 2
            let y = screen.frame.height - 100
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.orderFront(nil)
    }

    @MainActor
    func hide() {
        window?.orderOut(nil)
    }
}

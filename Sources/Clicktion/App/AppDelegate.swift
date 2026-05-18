import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var serviceManager: ServiceManager!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        serviceManager = ServiceManager()
        serviceManager.start()

        setupStatusItem()
        setupPopover()

        if !AppState.shared.hasCompletedSetup {
            // Mark complete immediately so closing the window early doesn't re-show it.
            // Model management is always available from the menu.
            AppState.shared.hasCompletedSetup = true
            showSetupWizard()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        serviceManager.stop()
    }

    @MainActor private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        // "scope" is the SF Symbol that matches the crosshair-in-circle web logo.
        button.image = NSImage(systemSymbolName: "scope",
                               accessibilityDescription: "Clicktion")
        button.action = #selector(togglePopover)
        button.target = self
    }

    @MainActor private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh the badge + menu count so it reflects reality now,
            // not the last 60-second poll.
            Task { await serviceManager.refreshTodoCount() }
        }
    }

    @MainActor private func showSetupWizard() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Clicktion"
        window.center()
        window.contentViewController = NSHostingController(rootView: SetupWizardView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func updateTodoBadge(count: Int) {
        guard let button = statusItem.button else { return }
        let label = count > 0 ? "Clicktion — \(count) todo(s)" : "Clicktion"
        button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: label)
    }
}

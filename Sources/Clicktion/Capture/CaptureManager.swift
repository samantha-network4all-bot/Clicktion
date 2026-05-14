import ScreenCaptureKit
import AppKit

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    static let shared = CaptureManager()

    @Published var lastCapture: CaptureResult?

    private override init() {}

    func startCapture() async {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
        // Permission is handled naturally by the picker on first use.
        // If it fails, contentSharingPickerStartDidFailWithError is called.
    }
}

extension CaptureManager: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            do {
                var result = try await performCapture(with: filter)
                result.ocrText = try? await OCRProcessor.recognize(image: result.image)
                self.lastCapture = result
                picker.isActive = false
                CaptureDialogWindow.shared.show(capture: result)
            } catch {
                showError(error)
            }
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            // Check if it's a permission error and give a targeted message
            let nsError = error as NSError
            let isPermission = nsError.domain == "com.apple.ScreenCaptureKit.SCStreamError"
                || nsError.code == 1
                || error.localizedDescription.localizedCaseInsensitiveContains("permission")
                || error.localizedDescription.localizedCaseInsensitiveContains("access")

            if isPermission {
                showPermissionAlert()
            } else {
                showError(error)
            }
        }
    }

    private func performCapture(with filter: SCContentFilter) async throws -> CaptureResult {
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * 2)
        config.height = Int(filter.contentRect.height * 2)
        config.scalesToFit = true
        config.capturesAudio = false  // we only want the screen, not audio

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return CaptureResult(
            image: NSImage(cgImage: image, size: filter.contentRect.size),
            appName: nil,
            windowTitle: nil,
            timestamp: Date()
        )
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
            Clicktion needs screen recording access to capture screenshots.

            Open System Settings → Privacy & Security → Screen Recording \
            and enable Clicktion, then try again.

            Note: during development, macOS asks again after every rebuild \
            because the app binary changes. This won't happen with a signed release.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
            )
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct CaptureResult {
    let image: NSImage
    let appName: String?
    let windowTitle: String?
    let timestamp: Date
    var ocrText: String?
    var isPrivate: Bool = true
}

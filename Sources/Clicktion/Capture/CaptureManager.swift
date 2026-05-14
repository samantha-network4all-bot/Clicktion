import ScreenCaptureKit
import AppKit

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    static let shared = CaptureManager()

    @Published var lastCapture: CaptureResult?

    private override init() {}

    func startCapture() async {
        // Check permission first. SCShareableContent.current throws if the user
        // hasn't granted screen recording access yet.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            showPermissionAlert()
            return
        }

        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Clicktion needs screen recording access to capture screenshots.\n\nOpen System Settings → Privacy & Security → Screen Recording and enable Clicktion, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
            )
        }
    }

    private func showCaptureErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
                showCaptureErrorAlert(error)
            }
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            showCaptureErrorAlert(error)
        }
    }

    private func performCapture(with filter: SCContentFilter) async throws -> CaptureResult {
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * 2)
        config.height = Int(filter.contentRect.height * 2)
        config.scalesToFit = true

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
}

struct CaptureResult {
    let image: NSImage
    let appName: String?
    let windowTitle: String?
    let timestamp: Date
    var ocrText: String?
    var isPrivate: Bool = true
}

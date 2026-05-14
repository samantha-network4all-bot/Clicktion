import ScreenCaptureKit
import AppKit

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    static let shared = CaptureManager()

    @Published var lastCapture: CaptureResult?

    private override init() {}

    func startCapture() async throws {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
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
                print("Capture failed: \(error)")
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        print("Picker error: \(error)")
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

        let appName = extractAppName(from: filter)
        let windowTitle = extractWindowTitle(from: filter)

        return CaptureResult(
            image: NSImage(cgImage: image, size: filter.contentRect.size),
            appName: appName,
            windowTitle: windowTitle,
            timestamp: Date()
        )
    }

    private func extractAppName(from filter: SCContentFilter) -> String? {
        // SCContentFilter doesn't expose windows directly after iOS 17 API changes
        // App name is captured via the picker context stored separately
        return nil
    }

    private func extractWindowTitle(from filter: SCContentFilter) -> String? {
        return nil
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

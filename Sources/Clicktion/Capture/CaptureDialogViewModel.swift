import AppKit
import SwiftUI

@MainActor
final class CaptureDialogViewModel: ObservableObject {
    let capture: CaptureResult

    @Published var ocrText: String = ""
    @Published var isOCRRunning: Bool = true
    @Published var isPrivate: Bool = true
    @Published var availableSkills: [Skill] = []
    @Published var selectedSkill: Skill?
    @Published var isSuggestingSkill: Bool = false
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var inputMode: Skill.InputMode = .imageAndText
    @Published var useThinkingProfile: Bool = true

    // Annotation state
    @Published var activeTool: AnnotationTool = .none
    @Published var annotations: [Annotation] = []
    @Published var croppedImage: NSImage?       // set when rectangle is finalized

    /// The image that will actually be sent — cropped if a rectangle was drawn.
    var effectiveImage: NSImage { croppedImage ?? capture.image }

    private var captureRecord: CaptureRecord?

    init(capture: CaptureResult) {
        self.capture = capture
        // Mirror the privacy mode: private-only forces true, public-enabled defaults to false.
        // The capture.isPrivate already reflects this default; we just enforce the floor.
        self.isPrivate = capture.isPrivate
    }

    func onAppear() {
        loadSkills()
        runOCR()
    }

    // MARK: - Annotation actions

    func undo() {
        // Undo crop first if one exists
        if croppedImage != nil {
            croppedImage = nil
            captureRecord = nil
            Task { ocrText = (try? await OCRProcessor.recognize(image: capture.image)) ?? "" }
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func rectangleFinalized(_ unitRect: CGRect) {
        // Remove the rectangle overlay — the cropped image replaces it visually
        if case .rectangle = annotations.last?.kind {
            annotations.removeLast()
        }
        activeTool = .none
        guard let cropped = capture.image.cropping(to: unitRect) else { return }
        croppedImage = cropped
        captureRecord = nil
        Task {
            isOCRRunning = true
            ocrText = (try? await OCRProcessor.recognize(image: cropped)) ?? ""
            isOCRRunning = false
        }
    }

    // MARK: - Send

    func send(completion: @escaping (String?, String?, Skill?) -> Void) {
        guard let skill = selectedSkill else { completion(nil, nil, nil); return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let record: CaptureRecord
                if let existing = captureRecord {
                    record = existing
                } else {
                    record = try await doSubmitCapture()
                    captureRecord = record
                }
                let job = try await ServiceClient.shared.startJob(captureID: record.id, skill: skill, inputMode: inputMode, useThinkingProfile: useThinkingProfile)
                completion(job.id, record.id, skill)
            } catch {
                errorMessage = error.localizedDescription
                completion(nil, nil, skill)
            }
        }
    }

    // MARK: - Private

    private func loadSkills() {
        availableSkills = (try? SkillLoader.shared.loadAll()) ?? []
        selectedSkill = availableSkills.first
        inputMode = selectedSkill?.inputMode ?? .imageAndText
    }

    func skillDidChange(_ skill: Skill?) {
        inputMode = skill?.inputMode ?? .imageAndText
    }

    private func runOCR() {
        isOCRRunning = true
        Task {
            ocrText = (try? await OCRProcessor.recognize(image: capture.image)) ?? ""
            isOCRRunning = false
            await submitAndSuggestSkill()
        }
    }

    private func submitAndSuggestSkill() async {
        isSuggestingSkill = true
        defer { isSuggestingSkill = false }
        do {
            let record = try await doSubmitCapture()
            captureRecord = record
            if let name = record.suggestedSkill,
               let match = availableSkills.first(where: { $0.name == name }) {
                selectedSkill = match
            }
        } catch {
            errorMessage = "Skill suggestion unavailable: \(error.localizedDescription)"
        }
    }

    private func doSubmitCapture() async throws -> CaptureRecord {
        // Composite any freedraw/text annotations onto the image before encoding
        let imageToSend = annotations.isEmpty
            ? effectiveImage
            : effectiveImage.compositing(annotations)

        guard let pngData = imageToSend.pngData() else {
            throw CaptureError.encodingFailed
        }

        let payload = CapturePayload(
            imageBase64: pngData.base64EncodedString(),
            ocrText: ocrText,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            isPrivate: isPrivate,
            availableSkills: availableSkills.map { SkillInfo(name: $0.name, triggers: $0.triggers) }
        )
        let record = try await ServiceClient.shared.submitCapture(payload)
        let cap = AppState.shared.maxDiskUsageMB
        Task.detached { await ServiceClient.shared.pruneStorage(maxMB: cap) }
        return record
    }

    enum CaptureError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "Could not encode screenshot as PNG." }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

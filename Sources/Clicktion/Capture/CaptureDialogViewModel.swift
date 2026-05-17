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
    @Published var sendImage: Bool = true

    // Annotation state
    @Published var activeTool: AnnotationTool = .none
    @Published var annotations: [Annotation] = []
    @Published var textNote: String = ""        // text tool input
    @Published var croppedImage: NSImage?       // set when rectangle is finalized

    /// The image that will actually be sent — cropped if a rectangle was drawn.
    var effectiveImage: NSImage { croppedImage ?? capture.image }

    private var captureRecord: CaptureRecord?

    init(capture: CaptureResult) {
        self.capture = capture
        // In private-only mode, always force private regardless of capture default.
        self.isPrivate = AppState.shared.privacyMode == .privateOnly ? true : capture.isPrivate
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

    func commitTextAnnotation() {
        let note = textNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        // Place text at center of image as a canvas overlay
        annotations.append(Annotation(kind: .text(note, CGPoint(x: 0.05, y: 0.9))))
        textNote = ""
        activeTool = .none
    }

    // MARK: - Send

    func send(completion: @escaping (String?, Skill?) -> Void) {
        guard let skill = selectedSkill else { completion(nil, nil); return }
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
                let job = try await ServiceClient.shared.startJob(captureID: record.id, skill: skill, sendImage: sendImage)
                completion(job.id, skill)
            } catch {
                errorMessage = error.localizedDescription
                completion(nil, skill)
            }
        }
    }

    // MARK: - Private

    private func loadSkills() {
        availableSkills = (try? SkillLoader.shared.loadAll()) ?? []
        selectedSkill = availableSkills.first
        sendImage = selectedSkill?.inputMode != .textOnly
    }

    func skillDidChange(_ skill: Skill?) {
        sendImage = skill?.inputMode != .textOnly
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

        // Include text note as extra OCR context if present
        let combinedOCR = textNote.isEmpty ? ocrText : "\(ocrText)\n\n[User note]\n\(textNote)"

        let payload = CapturePayload(
            imageBase64: pngData.base64EncodedString(),
            ocrText: combinedOCR,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            isPrivate: isPrivate,
            availableSkills: availableSkills.map { SkillInfo(name: $0.name, triggers: $0.triggers) }
        )
        return try await ServiceClient.shared.submitCapture(payload)
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

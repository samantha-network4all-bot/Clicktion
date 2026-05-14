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

    private var captureRecord: CaptureRecord?

    init(capture: CaptureResult) {
        self.capture = capture
        self.isPrivate = capture.isPrivate
    }

    func onAppear() {
        loadSkills()
        runOCR()
    }

    // MARK: - Send

    /// Called when the user hits Send. Submits the capture if not already done
    /// (handles the case where the service wasn't ready when OCR finished),
    /// then starts the LLM job.
    func send(completion: @escaping (String?, Skill?) -> Void) {
        guard let skill = selectedSkill else {
            completion(nil, nil)
            return
        }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let record: CaptureRecord
                if let existing = captureRecord {
                    record = existing
                } else {
                    // Service wasn't ready during OCR — submit now
                    record = try await doSubmitCapture()
                    captureRecord = record
                }
                let job = try await ServiceClient.shared.startJob(captureID: record.id, skill: skill)
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
    }

    private func runOCR() {
        isOCRRunning = true
        Task {
            ocrText = (try? await OCRProcessor.recognize(image: capture.image)) ?? ""
            isOCRRunning = false
            await submitAndSuggestSkill()
        }
    }

    /// Best-effort background submit + skill suggestion after OCR.
    /// If this fails the user can still hit Send, which retries.
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
            // Non-fatal — user can still Send and the capture will be submitted then
            errorMessage = "Skill suggestion unavailable: \(error.localizedDescription)"
        }
    }

    private func doSubmitCapture() async throws -> CaptureRecord {
        guard let pngData = capture.image.pngData() else {
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
        return try await ServiceClient.shared.submitCapture(payload)
    }

    enum CaptureError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "Could not encode screenshot as PNG." }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

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

    private func loadSkills() {
        availableSkills = (try? SkillLoader.shared.loadAll()) ?? []
    }

    private func runOCR() {
        isOCRRunning = true
        Task {
            do {
                let text = try await OCRProcessor.recognize(image: capture.image)
                ocrText = text
            } catch {
                ocrText = ""
            }
            isOCRRunning = false
            await submitAndSuggestSkill()
        }
    }

    private func submitAndSuggestSkill() async {
        guard AppState.shared.isServiceReady else { return }
        guard let pngData = capture.image.pngData() else { return }

        isSuggestingSkill = true
        defer { isSuggestingSkill = false }

        let skillInfos = availableSkills.map { SkillInfo(name: $0.name, triggers: $0.triggers) }
        let payload = CapturePayload(
            imageBase64: pngData.base64EncodedString(),
            ocrText: ocrText,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            isPrivate: isPrivate,
            availableSkills: skillInfos
        )

        do {
            let record = try await ServiceClient.shared.submitCapture(payload)
            captureRecord = record
            if let name = record.suggestedSkill {
                selectedSkill = availableSkills.first { $0.name == name }
            }
            if selectedSkill == nil {
                selectedSkill = availableSkills.first
            }
        } catch {
            errorMessage = "Could not reach service: \(error.localizedDescription)"
            selectedSkill = availableSkills.first
        }
    }

    // Called when user hits Send — starts the job with the confirmed skill.
    func send(completion: @escaping (String?, Skill?) -> Void) {
        guard let record = captureRecord, let skill = selectedSkill else {
            // No service connection — pass nil so the chat window shows an error state
            completion(nil, selectedSkill)
            return
        }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let job = try await ServiceClient.shared.startJob(captureID: record.id, skill: skill)
                completion(job.id, skill)
            } catch {
                errorMessage = "Failed to start: \(error.localizedDescription)"
                completion(nil, skill)
            }
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

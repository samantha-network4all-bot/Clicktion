import Foundation

/// Lifecycle of a dictation session, also drives the listening indicator.
enum SpeechState: Equatable {
    case idle
    case requestingMicPermission
    case downloadingModel(Double)
    case listening
    case transcribing
    case inserting
}

/// A transcription plus the language hint that produced it (nil = auto-detect).
struct TranscriptionResult: Sendable {
    let text: String
    let languageCode: String?
}

protocol ParakeetEngineProtocol: AnyObject {
    /// Loaded into memory and ready to transcribe.
    var isLoaded: Bool { get }
    /// Model weights are present on disk (may or may not be loaded yet).
    var isDownloaded: Bool { get }
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws
    /// Transcribes with each hint ("nl"/"en") and returns the highest-confidence
    /// result. An empty array means auto-detect (single pass, no hint).
    func transcribe(_ samples: [Float], sampleRate: Double, languageHints: [String]) async throws -> TranscriptionResult
    /// Unloads from memory and deletes the cached weights from disk.
    func removeModel() throws
}

enum SpeechError: LocalizedError {
    case micDenied
    case accessibilityDenied
    case engineNotReady
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .micDenied: "Microphone access denied"
        case .accessibilityDenied: "Accessibility access required for text insertion"
        case .engineNotReady: "Speech engine not loaded"
        case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
        }
    }
}

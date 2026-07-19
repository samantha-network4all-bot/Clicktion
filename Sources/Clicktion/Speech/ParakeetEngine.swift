import Foundation
import os
import FluidAudio

final class ParakeetEngine: ParakeetEngineProtocol {
    private var asrManager: AsrManager?
    private var loadedModels = false
    private let lock = OSAllocatedUnfairLock()
    private let log = Logger(subsystem: "com.clicktion.app", category: "Parakeet")

    var isLoaded: Bool { lock.withLock { loadedModels } }

    /// True when the v3 weights exist on disk, whether or not they're loaded.
    var isDownloaded: Bool {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return false }
        return contents.contains { $0.pathExtension == "mlmodelc" }
    }

    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        if lock.withLock({ loadedModels }) { return }

        await MainActor.run { progress(0) }

        let models = try await AsrModels.downloadAndLoad(version: .v3) { dlProgress in
            let p = dlProgress.fractionCompleted
            Task { @MainActor in progress(p) }
        }

        // v3 is multilingual: the default `melChunkContext: true` biases chunk
        // boundaries back toward English (FluidAudio issue #594). Disable it and
        // enable dual-decode arbitration — the documented v3-multilingual setup.
        let config = ASRConfig(melChunkContext: false, dualDecodeArbitration: true)
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        lock.withLock { asrManager = manager; loadedModels = true }

        await MainActor.run { progress(1.0) }
    }

    func transcribe(_ samples: [Float], sampleRate: Double, languageHints: [String]) async throws -> TranscriptionResult {
        let manager = lock.withLock { asrManager }
        guard let manager else { throw SpeechError.engineNotReady }

        // Derive the decoder-layer count from the loaded model instead of
        // hardcoding it (v2/v3 use 2, tdtCtc110m uses 1).
        let layers = await manager.decoderLayerCount
        let seconds = Double(samples.count) / sampleRate

        // Empty → one auto-detect pass. Otherwise decode once per hint and keep
        // the highest-confidence result (the right-language decode scores higher
        // because the wrong hint fights the acoustics / trips the blocklist).
        let candidates: [String?] = languageHints.isEmpty ? [nil] : languageHints

        var best: (text: String, confidence: Float, code: String?)?
        for code in candidates {
            // Map the ISO code to FluidAudio's Language enum; nil = auto-detect.
            let language = code.flatMap { Language(rawValue: $0) }
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try await manager.transcribe(samples, decoderState: &state, language: language)
            log.debug("""
                transcribe \(String(format: "%.2f", seconds))s hint=\(code ?? "auto") \
                conf=\(String(format: "%.2f", result.confidence)) → \"\(result.text)\"
                """)
            if best == nil || result.confidence > best!.confidence {
                best = (result.text, result.confidence, code)
            }
        }

        if candidates.count > 1 {
            log.debug("picked language=\(best?.code ?? "auto") conf=\(String(format: "%.2f", best?.confidence ?? 0))")
        }
        return TranscriptionResult(text: best?.text ?? "", languageCode: best?.code)
    }

    func removeModel() throws {
        // Drop the in-memory model first so nothing keeps using the files.
        lock.withLock { asrManager = nil; loadedModels = false }

        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

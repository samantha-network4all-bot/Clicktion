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

    func transcribe(_ samples: [Float], sampleRate: Double, languageHint: String?) async throws -> String {
        let manager = lock.withLock { asrManager }
        guard let manager else { throw SpeechError.engineNotReady }

        // Derive the decoder-layer count from the loaded model instead of
        // hardcoding it (v2/v3 use 2, tdtCtc110m uses 1).
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // Map the ISO code to FluidAudio's Language enum; nil = auto-detect
        // (the hint is a v3-only script filter, silently ignored otherwise).
        let language = languageHint.flatMap { Language(rawValue: $0) }
        let seconds = Double(samples.count) / sampleRate
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        log.debug("""
            transcribe: \(samples.count) samples (\(String(format: "%.2f", seconds))s), \
            hint=\(languageHint ?? "auto"), conf=\(String(format: "%.2f", result.confidence)) \
            → \"\(result.text)\"
            """)
        return result.text
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

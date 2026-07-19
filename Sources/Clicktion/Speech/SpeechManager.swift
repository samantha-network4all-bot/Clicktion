import AVFoundation
import AppKit
import Carbon
import os

enum SpeechState: Equatable {
    case idle
    case requestingMicPermission
    case downloadingModel(Double)
    case listening
    case transcribing
    case inserting
}

protocol ParakeetEngineProtocol: AnyObject {
    /// Loaded into memory and ready to transcribe.
    var isLoaded: Bool { get }
    /// Model weights are present on disk (may or may not be loaded yet).
    var isDownloaded: Bool { get }
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws
    /// `languageHint` is an ISO code ("nl"/"en") or nil for auto-detect.
    func transcribe(_ samples: [Float], sampleRate: Double, languageHint: String?) async throws -> String
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

    @MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    var parakeetEngineIsLoaded: Bool { parakeet?.isLoaded ?? false }

    /// Whether the model weights are present on disk. Published so Settings
    /// updates live after a download or removal.
    @Published private(set) var modelDownloaded = false

    @Published var state: SpeechState = .idle {
        didSet { updateIndicator() }
    }

    /// Where a completed transcription goes.
    private enum DictationMode { case activeApp, pad }
    private var dictationMode: DictationMode = .activeApp

    /// True while the Dictation Pad's STT switch is on (continuous listening).
    /// Published so the pad's toggle stays in sync even when the hotkey flips it.
    @Published private(set) var isPadDictating = false

    /// Delivers each finished (committed) segment to the Dictation Pad.
    var onPadTranscription: ((String) -> Void)?
    /// Delivers the live, in-progress transcript of the current segment.
    var onPadPartial: ((String) -> Void)?

    private var hotKey: HotKey?
    private var audioEngine: AVAudioEngine?
    private var parakeet: ParakeetEngineProtocol?
    private let sampleBuffer = AudioSampleBuffer()
    private var silenceTimer: Task<Void, Never>?
    private let indicator = ListeningIndicatorWindow()
    private let log = Logger(subsystem: "com.clicktion.app", category: "SpeechManager")

    /// A committed segment must be at least this long, so passing noise blips
    /// aren't transcribed in isolation (which the v3 model mis-detects).
    private let minSegmentSamples = 9_600   // 0.6 s at 16 kHz
    /// Guards against overlapping segment transcriptions in continuous mode.
    private var isCommittingSegment = false
    /// Guards against overlapping live-partial transcriptions.
    private var isTranscribingPartial = false
    /// Incremented on each commit; late partials from an older segment are dropped.
    private var segmentGeneration = 0
    /// Periodically re-transcribes the current segment for live (pseudo-streaming) text.
    private var partialTimer: Task<Void, Never>?
    private let partialInterval: TimeInterval = 0.8

    private init() {}

    // MARK: - Setup

    func setup(parakeetEngine: ParakeetEngineProtocol) {
        self.parakeet = parakeetEngine
        self.modelDownloaded = parakeetEngine.isDownloaded
        registerHotKey()
    }

    /// Checks microphone access at launch and prompts once if it hasn't been
    /// decided yet, so the first dictation doesn't stall on the system dialog.
    func primeMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            log.info("microphone permission undetermined — requesting at launch")
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        case .denied, .restricted:
            log.info("microphone access not granted at launch")
        case .authorized:
            log.debug("microphone access already granted")
        @unknown default:
            break
        }
    }

    func teardown() {
        hotKey?.unregister()
        stopPartialLoop()
        stopAudioEngine()
        indicator.hide()
    }

    private func updateIndicator() {
        switch state {
        case .idle:
            indicator.hide()
        case .requestingMicPermission:
            indicator.hide()
        case .downloadingModel, .listening, .transcribing:
            indicator.show(state: state)
        case .inserting:
            indicator.hide()
        }
    }

    // MARK: - HotKey

    private func registerHotKey() {
        let keyCode: UInt32 = 49 // kVK_Space
        let modifiers: UInt32 = UInt32(optionKey) // Option key
        hotKey = HotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggle()
            }
        }
    }

    // MARK: - Toggle

    private func toggle() {
        // While the pad is dictating, the hotkey turns it off (keeps the
        // pad's switch in sync via `isPadDictating`).
        if isPadDictating {
            setPadDictating(false)
            return
        }
        switch state {
        case .idle:
            beginDictation(mode: .activeApp)
        case .listening:
            stop()
        default:
            break
        }
    }

    // MARK: - Dictation Pad control

    /// Starts/stops continuous dictation into the Dictation Pad.
    func setPadDictating(_ on: Bool) {
        if on {
            guard !isPadDictating, case .idle = state else { return }
            isPadDictating = true
            beginDictation(mode: .pad)
        } else {
            guard isPadDictating else { return }
            isPadDictating = false
            // Transcribe and append the final segment; if we're mid-download or
            // mid-permission, the in-flight task bails on the `!isPadDictating` check.
            if case .listening = state { stop() }
        }
    }

    private func beginDictation(mode: DictationMode) {
        guard case .idle = state else { return }
        dictationMode = mode
        state = .requestingMicPermission

        Task {
            guard await requestMicrophonePermission() else {
                state = .idle
                isPadDictating = false
                showMicPermissionAlert()
                return
            }

            guard let parakeet else {
                state = .idle
                isPadDictating = false
                return
            }

            if !parakeet.isLoaded {
                state = .downloadingModel(0)
                do {
                    try await parakeet.prepare { [weak self] progress in
                        Task { @MainActor [weak self] in
                            if case .downloadingModel = self?.state ?? .idle {
                                self?.state = .downloadingModel(progress)
                            }
                        }
                    }
                } catch {
                    state = .idle
                    isPadDictating = false
                    showModelDownloadError(error)
                    return
                }
                modelDownloaded = true
            }

            // User may have switched the pad off during download.
            if mode == .pad && !isPadDictating {
                state = .idle
                return
            }

            startListening()
        }
    }

    private func stop() {
        guard case .listening = state else { return }
        silenceTimer?.cancel()
        silenceTimer = nil
        stopPartialLoop()
        segmentGeneration += 1            // drop any in-flight partials
        state = .transcribing
        stopAudioEngine()

        let samples = sampleBuffer.drain()
        let languageHint = AppState.shared.parakeetLanguageHint
        let mode = dictationMode

        Task {
            do {
                let text = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHint: languageHint) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                switch mode {
                case .pad:
                    // Final segment when the switch is turned off.
                    if !trimmed.isEmpty { onPadTranscription?(trimmed) }
                    state = .idle
                    dictationMode = .activeApp
                case .activeApp:
                    guard !trimmed.isEmpty else { state = .idle; return }
                    state = .inserting
                    let inserted = TextInserter.insert(text)
                    if !inserted { showAccessibilityAlert() }
                    state = .idle
                }
            } catch {
                log.error("transcription failed: \(error.localizedDescription)")
                state = .idle
                if mode == .pad {
                    isPadDictating = false
                    dictationMode = .activeApp
                } else {
                    showTranscriptionError(error)
                }
            }
        }
    }

    /// Continuous pad mode: transcribe the audio accumulated since the last
    /// commit and append it, **without stopping the engine** — so no audio is
    /// lost at the start of the next utterance. Called on each speech pause.
    private func commitPadSegment() {
        guard case .listening = state, dictationMode == .pad, isPadDictating else { return }
        guard !isCommittingSegment else { return }        // keep accumulating; commit on next pause
        guard sampleBuffer.count >= minSegmentSamples else {
            log.debug("skipping short segment (\(self.sampleBuffer.count) samples)")
            return
        }

        isCommittingSegment = true
        segmentGeneration += 1            // invalidate any in-flight partials for this segment
        let samples = sampleBuffer.drain()
        let languageHint = AppState.shared.parakeetLanguageHint

        Task {
            defer { isCommittingSegment = false }
            do {
                let text = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHint: languageHint) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onPadTranscription?(trimmed) }
            } catch {
                log.error("segment transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Live partials (pseudo-streaming)

    private func startPartialLoop() {
        partialTimer?.cancel()
        let interval = partialInterval
        partialTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.transcribePartial()
            }
        }
    }

    private func stopPartialLoop() {
        partialTimer?.cancel()
        partialTimer = nil
    }

    /// Transcribes the audio accumulated so far (without draining) and emits it
    /// as a live partial, so text appears while the user is still speaking.
    private func transcribePartial() {
        guard case .listening = state, dictationMode == .pad, isPadDictating else { return }
        guard !isCommittingSegment, !isTranscribingPartial else { return }
        guard sampleBuffer.count >= minSegmentSamples else { return }

        isTranscribingPartial = true
        let gen = segmentGeneration
        let samples = sampleBuffer.snapshot()
        let languageHint = AppState.shared.parakeetLanguageHint

        Task {
            defer { isTranscribingPartial = false }
            do {
                let text = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHint: languageHint) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Drop if this segment was committed while we were transcribing.
                if gen == segmentGeneration, isPadDictating { onPadPartial?(trimmed) }
            } catch {
                log.error("partial transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Audio Recording

    private func startListening() {
        sampleBuffer.reset()
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: false)!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state = .idle
            return
        }

        let silenceThreshold: Float = 0.02
        let silenceDuration: TimeInterval = 1.5
        let buffer = sampleBuffer
        // `wasSilence` is only ever touched from the (serial) audio-tap thread,
        // so we can track transitions without a lock and only signal on change.
        let silenceState = SilenceState()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] input, _ in
            guard let converted = Self.resample(input, using: converter, to: targetFormat),
                  let floatData = converted.floatChannelData else { return }

            let frames = Int(converted.frameLength)
            guard frames > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            buffer.append(samples)

            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frames))
            let isSilence = rms < silenceThreshold
            guard isSilence != silenceState.wasSilence else { return }
            silenceState.wasSilence = isSilence

            // Hand off to the main actor; all `state`/`silenceTimer` access lives there.
            Task { @MainActor [weak self] in
                self?.handleSilenceChange(isSilence: isSilence, duration: silenceDuration)
            }
        }

        do {
            try engine.start()
            state = .listening
            if dictationMode == .pad { startPartialLoop() }
        } catch {
            state = .idle
        }
    }

    private func handleSilenceChange(isSilence: Bool, duration: TimeInterval) {
        guard case .listening = state else { return }
        silenceTimer?.cancel()
        guard isSilence else { silenceTimer = nil; return }

        silenceTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, case .listening = self.state else { return }
            if self.dictationMode == .pad {
                self.commitPadSegment()   // continuous: transcribe segment, keep recording
            } else {
                self.stop()               // one-shot: transcribe and paste
            }
        }
    }

    /// Downsamples one input buffer to `format`. Supplies the input exactly once
    /// so the converter never re-processes the same samples.
    private static func resample(_ input: AVAudioPCMBuffer,
                                 using converter: AVAudioConverter,
                                 to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error { return nil }
        return output.frameLength > 0 ? output : nil
    }

    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    // MARK: - Model Management

    /// Kicks off a download from Settings. Progress is surfaced via `state`
    /// (which also drives the floating indicator); errors are shown as an alert.
    func downloadModelFromSettings() {
        guard case .idle = state, let parakeet, !parakeet.isDownloaded else { return }
        state = .downloadingModel(0)
        Task {
            do {
                try await parakeet.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in
                        if case .downloadingModel = self?.state ?? .idle {
                            self?.state = .downloadingModel(progress)
                        }
                    }
                }
                modelDownloaded = true
                state = .idle
            } catch {
                state = .idle
                showModelDownloadError(error)
            }
        }
    }

    func removeModel() {
        guard case .idle = state else { return }
        do {
            try parakeet?.removeModel()
            modelDownloaded = false
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Remove Parakeet Model"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Alerts

    private func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = """
            Clicktion needs microphone access for the Parakeet dictation feature.

            Open System Settings → Privacy & Security → Microphone \
            and enable Clicktion, then try again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!)
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
            Clicktion needs Accessibility access to insert transcribed text into your active application.

            Open System Settings → Privacy & Security → Accessibility \
            and add Clicktion.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func showModelDownloadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to Download Parakeet Model"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showTranscriptionError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Transcription Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Lock-protected sample store. The audio tap appends from a real-time thread
/// while the main actor drains it, so all access is serialized behind a lock.
final class AudioSampleBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples = [Float]()

    var count: Int { lock.withLock { samples.count } }

    /// A copy of the accumulated samples without clearing them (for live partials).
    func snapshot() -> [Float] { lock.withLock { samples } }

    func append(_ new: [Float]) {
        lock.withLock { samples.append(contentsOf: new) }
    }

    func drain() -> [Float] {
        lock.withLock {
            let out = samples
            samples.removeAll(keepingCapacity: true)
            return out
        }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }
}

/// Tracks the previous silence state. Touched only from the serial audio-tap
/// thread, so no locking is needed; the class exists so the tap closure can
/// mutate it by reference.
final class SilenceState: @unchecked Sendable {
    var wasSilence = false
}

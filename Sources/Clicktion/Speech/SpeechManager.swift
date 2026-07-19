import AVFoundation
import AppKit
import Carbon
import FluidAudio
import os

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
    private enum DictationMode { case activeApp, pad, agent }
    private var dictationMode: DictationMode = .activeApp

    /// True while the Dictation Pad's STT switch is on (continuous listening).
    /// Published so the pad's toggle stays in sync even when the hotkey flips it.
    @Published private(set) var isPadDictating = false

    /// Delivers each finished (committed) segment to the Dictation Pad.
    var onPadTranscription: ((String) -> Void)?
    /// Delivers the live, in-progress transcript of the current segment.
    var onPadPartial: ((String) -> Void)?
    /// Reports a recoverable error to the Dictation Pad (shown inline).
    var onPadError: ((String) -> Void)?
    /// Delivers a finished spoken instruction to the browser agent.
    var onAgentInstruction: ((String) -> Void)?

    private var hotKey: HotKey?
    private var pushMonitor: PushToHoldMonitor?
    /// True during a push-to-hold session (stops only on key release, not on silence).
    private var isPushToHold = false
    /// Whether the push-to-hold key is currently held (guards the async start path).
    private var pushKeyHeld = false
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
    /// Winning language of the last committed segment (bilingual auto mode).
    /// Live partials reuse it to stay cheap and stable between commits.
    private var lastAutoLanguage: String?

    // MARK: Voice activity detection (segmentation)

    /// Silero VAD for speech-boundary detection. When nil (not loaded / offline)
    /// we fall back to the RMS energy heuristic.
    private var vad: VadManager?
    private var vadState: VadStreamState?
    private var vadLoop: Task<Void, Never>?
    private let vadFeed = AudioSampleBuffer()
    /// A touch more forgiving than the 0.75 s default so mid-sentence pauses
    /// don't end a segment prematurely.
    private let vadSegConfig = VadSegmentationConfig(minSilenceDuration: 1.0)

    /// Hints for a committed segment (full set — may trigger bilingual arbitration).
    private var commitHints: [String] { AppState.shared.parakeetLanguageHints }

    /// Hints for a live partial: reuse the last winning language in bilingual
    /// mode so partials stay single-pass; forced languages pass through as-is.
    private var partialHints: [String] {
        let hints = AppState.shared.parakeetLanguageHints
        guard hints.count > 1 else { return hints }        // forced language
        return lastAutoLanguage.map { [$0] } ?? []          // [] = plain auto-detect
    }

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

    /// Loads the VAD model in the background at launch so the first dictation
    /// already has smart segmentation (falls back to RMS if it isn't ready).
    func primeVad() {
        Task { await ensureVad() }
    }

    private func ensureVad() async {
        guard vad == nil else { return }
        do {
            vad = try await VadManager()
            log.debug("VAD model loaded")
        } catch {
            log.error("VAD load failed, using RMS fallback: \(error.localizedDescription)")
            vad = nil
        }
    }

    func teardown() {
        hotKey?.unregister()
        pushMonitor?.stop()
        stopPartialLoop()
        stopVadLoop()
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
        hotKey?.unregister()
        hotKey = nil
        pushMonitor?.stop()
        pushMonitor = nil

        let combo = AppState.shared.dictationHotKey

        if AppState.shared.dictationHotKeyMode == "hold" {
            let monitor = PushToHoldMonitor(
                keyCode: combo.keyCode,
                carbonModifiers: combo.modifiers,
                onPress: { [weak self] in Task { @MainActor [weak self] in self?.pushToHoldPressed() } },
                onRelease: { [weak self] in Task { @MainActor [weak self] in self?.pushToHoldReleased() } }
            )
            if monitor.start() {
                pushMonitor = monitor
            } else {
                // No Accessibility → the tap gets no events. Fall back to toggle
                // and tell the user how to enable push-to-hold.
                SystemAlert.warn(
                    "Push-to-hold needs Accessibility",
                    """
                    Enable Clicktion under System Settings → Privacy & Security → \
                    Accessibility to use push-to-hold. Falling back to toggle mode for now.
                    """,
                    settingsURL: SystemAlert.PrivacyPane.accessibility)
                registerCarbonHotKey(combo)
            }
        } else {
            registerCarbonHotKey(combo)
        }
    }

    private func registerCarbonHotKey(_ combo: HotKeyCombo) {
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggle()
            }
        }
    }

    /// Re-registers the global hotkey after the user changes it in Settings.
    func updateHotKey() {
        registerHotKey()
    }

    // MARK: - Push-to-hold

    private func pushToHoldPressed() {
        guard case .idle = state else { return }
        isPushToHold = true
        pushKeyHeld = true
        beginDictation(mode: .activeApp)
    }

    private func pushToHoldReleased() {
        pushKeyHeld = false
        guard isPushToHold else { return }
        if case .listening = state {
            stop()               // transcribe + paste what was said while held
        }
        // If we're still requesting permission / downloading, the beginDictation
        // task aborts via the `pushKeyHeld` check before it starts listening.
        isPushToHold = false
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

    /// One-shot spoken instruction for the browser agent: records until the
    /// speaker pauses, then delivers the transcript via `onInstruction`.
    func startAgentDictation(onInstruction: @escaping (String) -> Void) {
        guard case .idle = state else { return }
        onAgentInstruction = onInstruction
        beginDictation(mode: .agent)
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
            // Push-to-hold key was released before we were ready to listen.
            if isPushToHold && !pushKeyHeld {
                state = .idle
                isPushToHold = false
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
        stopVadLoop()
        segmentGeneration += 1            // drop any in-flight partials
        state = .transcribing
        stopAudioEngine()

        let samples = sampleBuffer.drain()
        let hints = commitHints
        let mode = dictationMode

        Task {
            do {
                let result = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHints: hints)
                let text = result?.text ?? ""
                if let code = result?.languageCode { lastAutoLanguage = code }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                switch mode {
                case .pad:
                    // Final segment when the switch is turned off.
                    if !trimmed.isEmpty { onPadTranscription?(trimmed) }
                    state = .idle
                    dictationMode = .activeApp
                case .agent:
                    if !trimmed.isEmpty { onAgentInstruction?(text) }
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
                    onPadError?("Transcription failed: \(error.localizedDescription)")
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
        let hints = commitHints

        Task {
            defer { isCommittingSegment = false }
            do {
                let result = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHints: hints)
                if let code = result?.languageCode { lastAutoLanguage = code }
                let trimmed = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onPadTranscription?(trimmed) }
            } catch {
                log.error("segment transcription failed: \(error.localizedDescription)")
                onPadError?("Couldn't transcribe that part: \(error.localizedDescription)")
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
        let hints = partialHints

        Task {
            defer { isTranscribingPartial = false }
            do {
                let result = try await parakeet?.transcribe(samples, sampleRate: 16000, languageHints: hints)
                let trimmed = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let feed = vadFeed
        let useVad = vad != nil
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

            if useVad {
                feed.append(samples)   // the VAD loop segments on speech-end
                return
            }

            // Fallback: RMS energy heuristic with a fixed silence timer.
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frames))
            let isSilence = rms < silenceThreshold
            guard isSilence != silenceState.wasSilence else { return }
            silenceState.wasSilence = isSilence
            Task { @MainActor [weak self] in
                self?.handleSilenceChange(isSilence: isSilence, duration: silenceDuration)
            }
        }

        do {
            try engine.start()
            state = .listening
            // Push-to-hold records until release, so no auto-stop segmentation.
            if useVad && !isPushToHold { startVadLoop() }
            if dictationMode == .pad { startPartialLoop() }
        } catch {
            state = .idle
            log.error("audio engine failed to start: \(error.localizedDescription)")
            if dictationMode == .pad {
                isPadDictating = false
                onPadError?("Couldn't start the microphone: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - VAD segmentation loop

    private func startVadLoop() {
        guard let vad else { return }
        vadFeed.reset()
        vadLoop = Task { @MainActor [weak self] in
            guard let self else { return }
            self.vadState = await vad.makeStreamState()
            while !Task.isCancelled {
                guard self.vadFeed.count >= VadManager.chunkSize,
                      let chunk = self.vadFeed.take(VadManager.chunkSize),
                      let currentState = self.vadState
                else {
                    try? await Task.sleep(nanoseconds: 40_000_000)   // 40 ms
                    continue
                }
                do {
                    let result = try await vad.processStreamingChunk(
                        chunk, state: currentState, config: self.vadSegConfig)
                    self.vadState = result.state
                    if result.event?.kind == .speechEnd {
                        self.handleSpeechEnd()
                    }
                } catch {
                    self.log.error("VAD chunk failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopVadLoop() {
        vadLoop?.cancel()
        vadLoop = nil
        vadState = nil
        vadFeed.reset()
    }

    /// A speech segment ended (VAD event or RMS-timer fallback).
    private func handleSpeechEnd() {
        guard case .listening = state else { return }
        if isPushToHold { return }   // hold sessions stop only on key release
        if dictationMode == .pad {
            commitPadSegment()   // continuous: transcribe segment, keep recording
        } else {
            stop()               // one-shot: transcribe and paste
        }
    }

    private func handleSilenceChange(isSilence: Bool, duration: TimeInterval) {
        guard case .listening = state else { return }
        silenceTimer?.cancel()
        guard isSilence else { silenceTimer = nil; return }

        silenceTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, case .listening = self.state else { return }
            self.handleSpeechEnd()
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
            SystemAlert.warn("Failed to Remove Parakeet Model", error.localizedDescription)
        }
    }

    // MARK: - Alerts

    private func showMicPermissionAlert() {
        SystemAlert.warn(
            "Microphone Access Required",
            """
            Clicktion needs microphone access for the Parakeet dictation feature.

            Open System Settings → Privacy & Security → Microphone \
            and enable Clicktion, then try again.
            """,
            settingsURL: SystemAlert.PrivacyPane.microphone)
    }

    private func showAccessibilityAlert() {
        SystemAlert.warn(
            "Accessibility Access Required",
            """
            Clicktion needs Accessibility access to insert transcribed text into your active application.

            Open System Settings → Privacy & Security → Accessibility and add Clicktion.
            """,
            settingsURL: SystemAlert.PrivacyPane.accessibility)
    }

    private func showModelDownloadError(_ error: Error) {
        SystemAlert.warn("Failed to Download Parakeet Model", error.localizedDescription)
    }

    private func showTranscriptionError(_ error: Error) {
        SystemAlert.warn("Transcription Failed", error.localizedDescription)
    }
}

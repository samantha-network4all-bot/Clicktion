# Clicktion — Speech-to-Text Feature (Parakeet) PRD

## Overview

Add a global dictation feature ("Parakeet") that lets users press a hotkey to
speak in Dutch or English and have the transcribed text inserted directly at the
current cursor position in any application — running the real **Parakeet** model
fully on-device.

---

## Constraints & Native Swift Feasibility

### Parakeet model (nvidia/parakeet-tdt-0.6b-v3)

The raw NVIDIA checkpoint is distributed for NeMo (PyTorch + CUDA) and cannot be
run in that form on macOS. **However, the model can run natively on Apple
Silicon** once converted to Core ML, and there are Swift-first packages that do
exactly this. The earlier assumption that Parakeet "cannot run in Swift" was
incorrect.

### Chosen approach: FluidAudio (Parakeet-TDT via Core ML)

We will use **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — a
Swift package that ships `parakeet-tdt-0.6b-v3` converted to **Core ML**, running
on the Apple Neural Engine:

- **The actual Parakeet model** (matches the feature name, not just branding)
- **Multilingual v3** — 25 European languages including **Dutch** and **English**
- **Always on-device** — no audio ever leaves the machine, aligning with
  Clicktion's `privacyMode`
- Pure Swift API; no Python / PyTorch / CUDA at runtime
- High throughput on the ANE

**Trade-offs to accept / verify:**

- Adds a **SwiftPM dependency** and a **one-time model download** (~600 MB of
  Core ML weights, cached on disk).
- Confirm the current state of **low-latency streaming** in FluidAudio for the
  toggle-to-stop UX. If streaming isn't ready, use **chunked near-real-time**
  transcription (transcribe the buffered audio on stop, or every N seconds).

> Alternative considered: `SFSpeechRecognizer` (Apple Speech). Rejected as the
> primary engine because on-device support is not guaranteed per-locale (can fall
> back to Apple's servers) and accuracy on Dutch is generally lower than
> Parakeet-v3. Kept in mind only as an emergency fallback.
>
> Alternative considered: `sherpa-onnx` (ONNX Runtime, has Swift bindings). Viable
> and streaming-capable, but heavier C-interop; revisit only if FluidAudio's
> streaming proves insufficient.

> ⚠️ FluidAudio's API surface is evolving. Treat all code below as illustrative
> and **verify symbol names against the pinned package version** during
> implementation.

---

## Feature: Voice Dictation ("Parakeet")

### User Flow

1. User presses **⌥Space** (Option + Space) from anywhere in macOS.
2. A small floating **listening indicator** appears (subtle, auto-dismissing).
3. Clicktion starts recording audio from the microphone.
4. Speech is transcribed on-device via the Parakeet Core ML model.
5. User presses **⌥Space** again (or speech pauses for 1.5 s) to stop.
6. Transcribed text is inserted at the current cursor position in the active app.
7. The listening indicator fades out.

First run only: the Parakeet model is downloaded (~600 MB) with a progress
indicator before the first transcription is possible.

> **Hotkey choice:** the original draft proposed `⌥→`, but that is macOS's built-in
> "move one word right" shortcut and would fight with text navigation. `⌥Space`
> is unbound by default on a clean macOS install and is a safer default. Make it
> configurable early (see Open Questions).

### Hotkey registration

Use **Carbon `RegisterEventHotKey`** (via a thin Swift wrapper) rather than
`NSEvent.addGlobalMonitorForEvents`:

| Approach | Consumes the key combo? | Needs Accessibility? | Notes |
|----------|-------------------------|----------------------|-------|
| `RegisterEventHotKey` (Carbon) | ✅ Yes | ❌ No | Simplest for a fixed global hotkey. Recommended. |
| `CGEventTap` | ✅ Yes (if you return `nil`) | ✅ Yes | More flexible (push-to-hold, chords) but heavier and needs Accessibility. |
| `NSEvent.addGlobalMonitorForEvents` | ❌ No | ✅ Yes (for keyDown) | **Do not use** — cannot suppress the key, so the combo still reaches the focused app. |

Toggle behaviour: first press starts listening, second press stops and inserts.

### Language Support

- `parakeet-tdt-0.6b-v3` is multilingual and can detect/transcribe **Dutch** and
  **English** (among 25 European languages) without a per-language model swap.
- Settings lets the user pin a language or choose **Auto / System**. `"system"`
  follows the current locale, matching the existing `responseLanguage` pattern in
  `AppState`.
- If the chosen FluidAudio configuration requires an explicit language hint, map
  the setting to the model's expected language code; otherwise rely on
  auto-detection.

### Permissions Required

| Permission | Key / API | Why |
|------------|-----------|-----|
| Microphone | `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` entitlement | Capture audio |
| Accessibility | `AXIsProcessTrusted()` (no plist key; user grants in System Settings) | Post ⌘V into the focused app |

> **No Speech Recognition permission needed.** Because we run our own Core ML
> model instead of `SFSpeechRecognizer`, `NSSpeechRecognitionUsageDescription` and
> the Speech-Recognition TCC prompt are **not** required. This is a concrete
> privacy win over the Apple Speech approach.

Microphone is requested on first Parakeet use with a clear explanation.
Accessibility cannot be requested programmatically — detect
`AXIsProcessTrusted() == false` and show an alert that deep-links to System
Settings (mirror the existing `showPermissionAlert()` pattern in
`CaptureManager`).

---

## Implementation Plan

### New Files

| File | Purpose |
|------|---------|
| `Sources/Clicktion/Speech/SpeechManager.swift` | Audio recording + Parakeet transcription orchestration; owns the recognition lifecycle |
| `Sources/Clicktion/Speech/ParakeetEngine.swift` | Wraps FluidAudio: model download/load, transcribe(samples) → text |
| `Sources/Clicktion/Speech/HotKey.swift` | Carbon `RegisterEventHotKey` wrapper (register/unregister, callback) |
| `Sources/Clicktion/Speech/TextInserter.swift` | Clipboard save/restore + ⌘V synthesis + Accessibility check |
| `Sources/Clicktion/Speech/ListeningIndicatorWindow.swift` | Borderless floating `NSWindow` controller |
| `Sources/Clicktion/Speech/ListeningIndicatorView.swift` | SwiftUI content (waveform / mic + "Listening…" / download progress) |

### Changes to Existing Files

| File | Changes |
|------|---------|
| `Package.swift` | Add the FluidAudio package dependency + link it into the `Clicktion` target |
| `Sources/Clicktion/App/AppDelegate.swift` | Instantiate `SpeechManager` in `applicationDidFinishLaunching`; hold a strong reference; tear down in `applicationWillTerminate` |
| `Clicktion.entitlements` | Add `com.apple.security.device.audio-input` |
| `Clicktion.app/Contents/Info.plist` | Add `NSMicrophoneUsageDescription` |
| `Sources/Clicktion/Settings/SettingsView.swift` | Add a **Parakeet** section (language picker, hotkey display, model-download status, permission status) |
| `Sources/Clicktion/App/AppState.swift` | Add `parakeetLanguage` (UserDefaults-backed, matching `responseLanguage`) |

### SpeechManager Architecture

```
SpeechManager  (@MainActor, ObservableObject, held by AppDelegate)
├── HotKey                      → ⌥Space toggles start/stop (Carbon)
├── AVAudioEngine               → captures mic audio, installs a tap on inputNode
│                                 (downsampled/converted to 16 kHz mono Float32)
├── ParakeetEngine (FluidAudio) → on-device Core ML transcription
├── ListeningIndicatorWindow    → shows/hides the floating indicator
└── TextInserter                → inserts the final transcript
```

State machine:
`idle → (first run) downloadingModel → requestingMicPermission → listening → transcribing → inserting → idle`.
Guard re-entrancy: ignore a start request while already `listening` unless it's
the toggle-to-stop.

### ParakeetEngine (FluidAudio wrapper — illustrative)

```swift
import FluidAudio  // verify module + symbol names against the pinned version

actor ParakeetEngine {
    private var asr: AsrManager?

    /// First call downloads (~600 MB) and loads the Core ML model; later calls are cheap.
    func prepare(progress: @Sendable (Double) -> Void) async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.downloadAndLoad()   // caches under Application Support
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        asr = manager
    }

    /// `samples`: 16 kHz mono Float32 PCM.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { throw SpeechError.notReady }
        let result = try await asr.transcribe(samples, source: .microphone)
        return result.text
    }
}
```

> **Streaming vs. chunked:** if FluidAudio exposes a streaming transcriber, feed
> converted buffers as they arrive and update `latestTranscript`. If not,
> accumulate the audio and transcribe once on stop (or in N-second chunks) — the
> toggle-to-stop UX tolerates a short post-speech delay. Keep this decision
> behind `ParakeetEngine` so it can change without touching `SpeechManager`.

### Audio capture format

Parakeet Core ML expects **16 kHz mono Float32**. `AVAudioEngine`'s input node
runs at the device's native rate (often 44.1/48 kHz). Convert with
`AVAudioConverter` in the tap, or install an `AVAudioMixerNode` to downsample,
before handing samples to `ParakeetEngine`.

### Text insertion (corrected)

The original snippet overwrote the user's clipboard permanently. Save and
restore it, and verify Accessibility first:

```swift
enum TextInserter {
    /// Returns false if Accessibility isn't granted (caller shows the alert).
    @MainActor
    static func insert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let pasteboard = NSPasteboard.general
        // Snapshot existing contents so we can restore them afterwards.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { dict[type] = item.data(forType: type) }
            return dict
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCommandV()

        // Restore after the paste has been delivered. 200 ms is a safe margin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let saved else { return }
            pasteboard.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }
        return true
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

> **Alternative:** the `AXUIElement` accessibility API (`kAXSelectedTextAttribute`)
> can insert text without touching the clipboard, but support is inconsistent
> across apps (Electron, web views). ⌘V synthesis is the pragmatic default; keep
> `TextInserter` as the single seam so the strategy can change later.

### Listening indicator

- Borderless floating `NSWindow` (~200×60 pt), `level: .floating`,
  `ignoresMouseEvents = true`, `isReleasedWhenClosed = false`, no activation
  (`styleMask: .borderless`, `canBecomeKey = false`) so it never steals focus
  from the target app.
- SwiftUI content: mic symbol + animated waveform + "Listening…"; on first run
  show a determinate **download progress** state instead.
- Positioned centered near the top of the active screen (`NSScreen.main`);
  auto-fades on stop.

---

## Permissions & Entitlements

### Info.plist additions (`Clicktion.app/Contents/Info.plist`)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Clicktion needs microphone access to transcribe speech when you use the Parakeet dictation feature.</string>
```

(No `NSSpeechRecognitionUsageDescription` — we run Parakeet on-device, not Apple
Speech.)

### Entitlements (`Clicktion.entitlements`) — **must be added**

The current entitlements file does **not** contain any audio keys. Because the
app is signed with the **hardened runtime** (`codesign --options runtime` in the
Makefile), microphone capture requires:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

(The app is not sandboxed — `com.apple.security.app-sandbox` is `false` — so no
`com.apple.security.device.microphone` sandbox entitlement is needed, and the
model download over the internet needs no extra entitlement.)

Accessibility (for ⌘V synthesis) is **not** an entitlement — it is a TCC
permission the user grants manually in **System Settings → Privacy & Security →
Accessibility**.

---

## How to Build (project-specific)

The app is a SwiftPM executable bundled by hand into `Clicktion.app` and
code-signed with the hardened runtime + entitlements. Speech features only work
from the **signed bundle**, not from `swift run`, because the entitlements and
Info.plist usage strings must be present.

### Workflow

1. **Add the FluidAudio dependency** in `Package.swift`:
   ```swift
   dependencies: [
       .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "<pin-a-version>")
   ],
   targets: [
       .executableTarget(
           name: "Clicktion",
           dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
           path: "Sources/Clicktion"
       )
   ]
   ```
   Pin an exact version; confirm the product/module name against the package.
2. **Add source files** under `Sources/Clicktion/Speech/`. SwiftPM picks them up
   automatically. `AVFoundation` and `Carbon` are system frameworks — no extra
   deps beyond FluidAudio.
3. **Edit `Clicktion.entitlements`** — add the audio-input key above.
4. **Edit `Clicktion.app/Contents/Info.plist`** — add the microphone usage string.
5. **Build + bundle + relaunch:**
   ```sh
   make dev
   ```
   `make dev` runs `swift build -c release`, copies the binary into the bundle,
   re-signs with entitlements + hardened runtime, and relaunches. Use
   `make swift-build` for a quick compile-only check during development.
6. **Grant permissions & download the model:** on first hotkey press, approve
   Microphone, then grant **Accessibility** manually (the app detects it's missing
   and deep-links there). The Parakeet model downloads on first use.

### Development caveats

- **Hardened runtime + FluidAudio:** Core ML on the ANE runs fine under hardened
  runtime, but if the package or its model loading trips a signing/JIT
  restriction, you may need `com.apple.security.cs.allow-jit` or
  `...disable-library-validation`. Add only if a runtime error demands it — don't
  add speculatively.
- **Model cache location:** FluidAudio downloads weights to a cache directory
  (Application Support). Verify the path and expose it in the download UI; ensure
  it survives app updates so users don't re-download ~600 MB.
- **Ad-hoc signing re-triggers TCC prompts.** The default `SIGNING_IDENTITY` is
  `-` (ad-hoc). Every rebuild changes the binary signature, so macOS re-asks for
  Microphone/Accessibility after each `make dev`. Set a stable `SIGNING_IDENTITY`
  in `Makefile.local` (an "Apple Development" cert) to keep grants sticky — the
  same trick already noted for Screen Recording in `CaptureManager`.
- **`LSUIElement` is true** — the app is a menu-bar accessory with no Dock icon.
  The indicator window must not call `NSApp.activate(...)`; it appears without
  taking focus.
- **`@MainActor` everywhere.** `AppState`, `CaptureManager`, and the UI are all
  `@MainActor`. Make `SpeechManager` `@MainActor`; run Parakeet inference off the
  main actor (`ParakeetEngine` is an `actor`) and marshal results back with
  `await`/`Task { @MainActor in … }`, as `CaptureManager` does for its capture
  callback.

---

## Settings

Add a **Parakeet** section to `SettingsView`:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Language | Picker | System | Dutch / English / Auto (System) (store `"system"` / `"nl"` / `"en"` like `responseLanguage`) |
| Hotkey | Display only | ⌥Space | Configurable later (see Open Questions) |
| Model | Status + action | — | Downloaded / Not downloaded, size, "Download now" / "Remove" |
| Permissions | Status rows | — | Live indicators for Mic / Accessibility with "Open Settings" buttons |

`AppState` addition (matching the existing UserDefaults `didSet` pattern):

```swift
@Published var parakeetLanguage: String =
    UserDefaults.standard.string(forKey: "parakeetLanguage") ?? "system" {
    didSet { UserDefaults.standard.set(parakeetLanguage, forKey: "parakeetLanguage") }
}
```

---

## Testing & Acceptance Criteria

- [ ] First run downloads the Parakeet model with visible progress; second run
      starts instantly (cache reused).
- [ ] Pressing the hotkey in TextEdit, Safari, and an Electron app (e.g. VS Code)
      inserts the transcript at the cursor.
- [ ] The hotkey combo does **not** leak to the focused app (no stray character /
      cursor jump).
- [ ] The user's clipboard is unchanged after dictation.
- [ ] Dutch and English both transcribe correctly; switching the Settings picker
      takes effect on the next dictation.
- [ ] Audio never leaves the device (no network traffic during transcription —
      only during the initial model download).
- [ ] Denying/revoking Microphone or Accessibility shows a clear, actionable
      alert (no silent failure).
- [ ] The indicator window never steals focus from the active app.
- [ ] Second hotkey press and a 1.5 s silence both stop-and-insert.
- [ ] Transcription latency after stop is acceptable (measure; target < ~1 s for
      short utterances on Apple Silicon).

---

## Open Questions

1. **Configurable hotkey** — ship `⌥Space` fixed first, add a `HotkeyRecorder`
   later? (Recommended: fixed first.)
2. **Streaming vs. chunked** — does the pinned FluidAudio version expose
   low-latency streaming, or do we transcribe on stop? (Spike this first — it
   shapes `SpeechManager`.)
3. **Continuous vs. push-to-hold vs. toggle** — start with toggle + silence
   auto-stop; push-to-hold needs `CGEventTap` and Accessibility up front.
4. **Model bundling** — download on first run (smaller app, needs network once)
   vs. ship weights in the bundle (huge `.app`, works offline immediately)?
   Recommended: download on first run.
5. **Auto-punctuation** — does Parakeet-v3 output punctuation/casing, or do we
   post-process?

---

## Future Enhancements

- Configurable hotkey (`HotkeyRecorder` component)
- Push-to-hold mode (`CGEventTap`)
- True streaming partial results in the indicator as you speak
- Punctuation voice commands ("comma", "period", "new line")
- Custom vocabulary / replacement rules
- Direct `AXUIElement` insertion to avoid the clipboard entirely
- Audio playback of selected text ("speak selection") via `AVSpeechSynthesizer`
- `sherpa-onnx` as an alternate engine if streaming needs outgrow FluidAudio
</content>

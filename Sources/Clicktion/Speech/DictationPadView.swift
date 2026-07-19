import SwiftUI

@MainActor
final class DictationPadViewModel: ObservableObject {
    /// Committed, user-editable text.
    @Published var committed: String = ""
    /// Live, in-progress transcript of the current segment (not yet committed).
    @Published var partial: String = ""
    /// A transient error banner shown inline (auto-dismisses).
    @Published var error: String?

    private var errorClearTask: Task<Void, Never>?

    /// Appends a finished dictation segment and clears the live partial.
    func appendFinal(_ segment: String) {
        committed = joined(committed, segment)
        partial = ""
    }

    func setPartial(_ p: String) { partial = p }

    func showError(_ message: String) {
        error = message
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.error = nil
        }
    }

    func clearError() {
        errorClearTask?.cancel()
        error = nil
    }

    func clear() {
        committed = ""
        partial = ""
    }

    /// Committed text plus the current live partial — what the field shows.
    var display: String { partial.isEmpty ? committed : joined(committed, partial) }

    private func joined(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        guard !next.isEmpty else { return base }
        let needsSpace = !(base.hasSuffix(" ") || base.hasSuffix("\n"))
        return base + (needsSpace ? " " : "") + next
    }
}

struct DictationPadView: View {
    @ObservedObject var vm: DictationPadViewModel
    @ObservedObject private var speech = SpeechManager.shared

    /// Copies + pastes the text into the previously-active app.
    let onCopyPaste: (String) -> Void

    /// The field shows committed + live partial. Edits are accepted only when no
    /// segment is in progress (partial empty), so live updates don't fight typing.
    private var fieldText: Binding<String> {
        Binding(
            get: { vm.display },
            set: { newValue in
                if vm.partial.isEmpty { vm.committed = newValue }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            DictationTextView(text: fieldText, autoScroll: speech.isPadDictating)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )

            if let error = vm.error {
                errorBanner(error)
            }

            footer
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { speech.isPadDictating },
                set: { speech.setPadDictating($0) }
            )) {
                Label("Dictation (\(AppState.shared.dictationHotKey.displayString))", systemImage: "mic.fill")
            }
            .toggleStyle(.switch)

            statusText

            Spacer()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch speech.state {
        case .downloadingModel(let p):
            Label("Downloading model… \(Int(p * 100))%", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .requestingMicPermission:
            Text("Requesting microphone…").font(.caption).foregroundStyle(.secondary)
        case .listening:
            Label("Listening…", systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
        case .idle, .inserting:
            EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button { vm.clearError() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity)
    }

    private var footer: some View {
        HStack {
            Text("\(vm.display.count) characters")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            Button("Clear") { vm.clear() }
                .disabled(vm.display.isEmpty)

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.display, forType: .string)
            }
            .disabled(vm.display.isEmpty)

            Button("Copy & Paste") { onCopyPaste(vm.display) }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.display.isEmpty)
        }
    }
}

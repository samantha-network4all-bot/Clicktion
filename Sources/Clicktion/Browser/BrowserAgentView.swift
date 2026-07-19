import SwiftUI

struct BrowserAgentView: View {
    @ObservedObject var vm: BrowserAgentViewModel
    @ObservedObject private var speech = SpeechManager.shared
    @State private var instruction = ""

    private var isListening: Bool {
        switch speech.state {
        case .listening, .requestingMicPermission, .transcribing: return true
        default: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                browser
                    .frame(width: geo.size.width * 0.75)
                Divider()
                sidePanel
                    .frame(width: geo.size.width * 0.25)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - Browser (left 3/4)

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Enter a URL", text: $vm.urlText, onCommit: vm.openURL)
                    .textFieldStyle(.roundedBorder)
                if vm.web.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            WebViewRepresentable(controller: vm.web)
        }
    }

    // MARK: - Side panel (right 1/4)

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assistant").font(.headline)

            transcript

            Divider()

            inputArea
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.log) { entry in
                        logRow(entry).id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.log.count) { _, _ in
                if let last = vm.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func logRow(_ entry: AgentLogEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text).font(.callout).fontWeight(.medium)
        case .assistant:
            Text(entry.text).font(.callout).foregroundStyle(.secondary)
        case .action:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.caption).foregroundStyle(.blue)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Type an instruction", text: $instruction, onCommit: send)
                    .textFieldStyle(.roundedBorder)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || vm.isRunning)
            }

            HStack {
                Button(action: speak) {
                    Label(isListening ? "Listening…" : "Speak", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.isRunning || isListening)

                if vm.isRunning {
                    Button(role: .destructive, action: vm.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            if vm.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func send() {
        let text = instruction
        instruction = ""
        vm.submit(text)
    }

    private func speak() {
        SpeechManager.shared.startAgentDictation { spoken in
            vm.submit(spoken)
        }
    }
}

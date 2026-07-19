import SwiftUI

struct BrowserAgentView: View {
    @ObservedObject var vm: BrowserAgentViewModel
    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var appState = AppState.shared
    @State private var instruction = ""

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

            controls

            inputArea
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { vm.loadModels() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ask before each action", isOn: $vm.confirmEachAction)
                .font(.caption)

            Toggle("Auto-accept cookie banners", isOn: $appState.browserAutoAcceptCookies)
                .font(.caption)

            HStack {
                Text("Agent model").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $appState.browserAgentModelID) {
                    Text("Default").tag("")
                    ForEach(vm.models) { model in
                        Text(model.name).tag(model.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }

            HStack {
                Text("Vision model").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $appState.browserVisionModelID) {
                    Text("Auto").tag("")
                    ForEach(vm.models) { model in
                        Text(model.supportsVision ? "👁 \(model.name)" : model.name)
                            .tag(model.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
        }
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
                .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                // Continuous mic: stays on so you can keep giving instructions
                // while the agent is still working.
                Button(action: toggleMic) {
                    Label(speech.isAgentDictating ? "Listening… (tap to stop)" : "Speak",
                          systemImage: speech.isAgentDictating ? "mic.fill" : "mic")
                        .frame(maxWidth: .infinity)
                }
                .tint(speech.isAgentDictating ? .red : nil)

                if vm.isRunning {
                    Button(role: .destructive, action: vm.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            if vm.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(pendingLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var pendingLabel: String {
        vm.pendingCount > 0 ? "Working… (\(vm.pendingCount) queued)" : "Working…"
    }

    private func send() {
        let text = instruction
        instruction = ""
        vm.submit(text)
    }

    private func toggleMic() {
        SpeechManager.shared.setAgentDictating(!speech.isAgentDictating)
    }
}

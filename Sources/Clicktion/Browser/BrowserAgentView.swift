import SwiftUI

struct BrowserAgentView: View {
    @ObservedObject var vm: BrowserAgentViewModel
    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var appState = AppState.shared
    @State private var instruction = ""
    @State private var showBenchmark = false

    var body: some View {
        // HSplitView (NSSplitView) hosts the WKWebView correctly and keeps the
        // URL field / side panel clickable next to the AppKit web view.
        HSplitView {
            browser
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            sidePanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - Browser (left)

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Enter a URL", text: $vm.urlText, onCommit: vm.openURL)
                    .textFieldStyle(.roundedBorder)
                Button("Go", action: vm.openURL)
                if vm.web.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            WebViewRepresentable(controller: vm.web)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Divider()

            HStack {
                Button {
                    vm.runBenchmark()
                    showBenchmark = true
                } label: {
                    Label("Benchmark model", systemImage: "checklist")
                }
                .disabled(vm.isRunning || vm.isBenchmarking)

                if vm.isBenchmarking {
                    ProgressView().controlSize(.small)
                    Button("Stop", role: .destructive) { vm.stop() }
                        .font(.caption)
                } else if !vm.benchmarkResults.isEmpty {
                    Button("Score \(vm.benchmarkScore)/\(vm.benchmarkResults.count)") {
                        showBenchmark = true
                    }
                    .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showBenchmark) { benchmarkSheet }
    }

    private var benchmarkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model Benchmark").font(.headline)
                Spacer()
                if !vm.benchmarkResults.isEmpty {
                    Text("Score \(vm.benchmarkScore)/\(vm.benchmarkResults.count)")
                        .font(.headline)
                        .foregroundStyle(vm.benchmarkScore == vm.benchmarkResults.count ? .green : .primary)
                }
            }

            if vm.isBenchmarking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(vm.benchmarkProgress).font(.caption).foregroundStyle(.secondary)
                }
            }

            List(vm.benchmarkResults) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.passed ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.callout).fontWeight(.medium)
                        Text(r.answer.isEmpty ? "(no answer)" : r.answer)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .frame(minHeight: 300)

            HStack {
                if vm.isBenchmarking {
                    Button("Stop", role: .destructive) { vm.stop() }
                }
                Spacer()
                Button("Close") { showBenchmark = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 480)
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

                if vm.isRunning || vm.isBenchmarking {
                    Button(role: .destructive, action: vm.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            if vm.isBenchmarking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(vm.benchmarkProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if vm.isRunning {
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

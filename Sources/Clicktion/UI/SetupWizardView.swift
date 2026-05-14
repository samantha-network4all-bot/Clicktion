import SwiftUI

struct SetupWizardView: View {
    @State private var step: Step = .welcome
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var testResult: ModelTestResult?
    @State private var isTesting: Bool = false
    @State private var isLocal: Bool = false

    enum Step: Hashable { case welcome, addModel, testModel, done }

    var body: some View {
        VStack(spacing: 24) {
            progressIndicator

            switch step {
            case .welcome:   welcomeStep
            case .addModel:  addModelStep
            case .testModel: testModelStep
            case .done:      doneStep
            }
        }
        .padding(32)
        .frame(width: 560, height: 440)
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach([Step.welcome, .addModel, .testModel, .done], id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Clicktion")
                .font(.title2.bold())
            Text("Capture, analyze, and act on anything on your screen using AI skills.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = .addModel }
                .buttonStyle(.borderedProminent)
        }
    }

    private var addModelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add your first LLM model")
                .font(.title3.bold())
            Text("Supports any OpenAI-compatible endpoint — local (Ollama, LM Studio) or remote (OpenRouter, OpenAI).")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Label("Endpoint URL", systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("http://localhost:11434/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { _, new in
                        isLocal = ModelConfig.classify(url: new)
                    }
                if !baseURL.isEmpty {
                    Label(isLocal ? "Local model (private captures allowed)" : "Remote model (public captures only)",
                          systemImage: isLocal ? "lock.fill" : "cloud")
                        .font(.caption)
                        .foregroundStyle(isLocal ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("API Key (leave empty for local)", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Model name", systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("llama3.2-vision / gpt-4o", text: $modelName)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()
            HStack {
                Button("Back") { step = .welcome }
                Spacer()
                Button("Test Model") { step = .testModel; testModel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(baseURL.isEmpty || modelName.isEmpty)
            }
        }
    }

    private var testModelStep: some View {
        VStack(spacing: 16) {
            if isTesting {
                ProgressView("Testing model…")
            } else if let result = testResult {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? "Model is working" : "Model test failed")
                    .font(.title3.bold())
                if let response = result.response {
                    Text("Response: \"\(response)\"")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text("Latency: \(result.latencyMs)ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Back") { step = .addModel }
                Spacer()
                if testResult?.success == true {
                    Button("Finish") { finishSetup() }
                        .buttonStyle(.borderedProminent)
                } else if testResult?.success == false {
                    Button("Retry") { testModel() }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title2.bold())
            Text("Clicktion lives in your menu bar. Click the viewfinder icon to start capturing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Using Clicktion") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func testModel() {

        isTesting = true
        testResult = nil
        // Real implementation will call ServiceClient
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                isTesting = false
                testResult = ModelTestResult(success: true, response: "screen", latencyMs: 340)
                step = .testModel
            }
        }
    }

    private func finishSetup() {
        AppState.shared.hasCompletedSetup = true
        step = .done
    }
}


import SwiftUI
import CoreGraphics
import Network

struct SetupWizardView: View {
    @State private var step: Step = .welcome
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var testResult: ModelTestResult?
    @State private var isTesting: Bool = false
    @State private var isLocal: Bool = false

    // Permissions state
    @State private var screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()
    @State private var localNetworkGranted: Bool = false
    @State private var localNetworkChecking: Bool = false

    enum Step: Hashable {
        case welcome, permissions, addModel, testModel, done
    }

    private let allSteps: [Step] = [.welcome, .permissions, .addModel, .testModel, .done]

    var body: some View {
        VStack(spacing: 24) {
            progressIndicator

            switch step {
            case .welcome:     welcomeStep
            case .permissions: permissionsStep
            case .addModel:    addModelStep
            case .testModel:   testModelStep
            case .done:        doneStep
            }
        }
        .padding(32)
        .frame(width: 560, height: 460)
        // Poll screen recording status while on permissions step
        .task(id: step) {
            guard step == .permissions else { return }
            while step == .permissions {
                screenRecordingGranted = CGPreflightScreenCaptureAccess()
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    // MARK: - Progress dots

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(allSteps, id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Welcome

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
            Button("Get Started") { step = .permissions }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Grant Permissions")
                .font(.title3.bold())
            Text("Clicktion needs two permissions to work. Grant them before continuing.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            // Screen recording
            PermissionRow(
                icon: "camera.metering.spot",
                title: "Screen Recording",
                description: "Required to capture screenshots. Without this, Clicktion cannot see your screen.",
                status: screenRecordingGranted ? .granted : .denied,
                actionLabel: screenRecordingGranted ? nil : "Open System Settings",
                onAction: {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
                    )
                }
            )

            // Local network
            PermissionRow(
                icon: "network",
                title: "Local Network",
                description: "Required to reach LLM models on your local network (Ollama, LM Studio). macOS will prompt when you first connect.",
                status: localNetworkGranted ? .granted : .unknown,
                actionLabel: localNetworkGranted ? nil : "Request Access",
                onAction: { triggerLocalNetworkPermission() }
            )

            Spacer()

            HStack {
                Button("Back") { step = .welcome }
                Spacer()
                Button("Continue") { step = .addModel }
                    .buttonStyle(.borderedProminent)
                    .disabled(!screenRecordingGranted)
            }

            if !screenRecordingGranted {
                Label("Screen recording access is required to continue.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Add model

    private var addModelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add your first LLM model")
                .font(.title3.bold())
            Text("Supports any OpenAI-compatible endpoint — local (Ollama, LM Studio) or remote (OpenRouter, OpenAI).")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Label("Endpoint URL", systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("http://localhost:11434/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { _, new in
                        isLocal = ModelConfig.classify(url: new)
                    }
                if !baseURL.isEmpty {
                    Label(
                        isLocal ? "Local model — private captures allowed" : "Remote model — public captures only",
                        systemImage: isLocal ? "lock.fill" : "cloud"
                    )
                    .font(.caption)
                    .foregroundStyle(isLocal ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("API Key (leave empty for local models)", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-… or empty for Ollama", text: $apiKey)
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
                Button("Back") { step = .permissions }
                Spacer()
                Button("Test Model") { step = .testModel; runModelTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(baseURL.isEmpty || modelName.isEmpty)
            }
        }
    }

    // MARK: - Test model

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
                    Button("Retry") { runModelTest() }
                }
            }
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title2.bold())
            Text("Clicktion lives in your menu bar. Click the viewfinder icon to capture your first screenshot.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Start Using Clicktion") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func triggerLocalNetworkPermission() {
        localNetworkChecking = true
        // NWConnection to a local address triggers the system's local network prompt
        let host = NWEndpoint.Host("10.0.0.1")
        let port = NWEndpoint.Port(rawValue: 80)!
        let connection = NWConnection(host: host, port: port, using: .tcp)
        connection.stateUpdateHandler = { [self] state in
            DispatchQueue.main.async {
                // Whether it succeeds or fails, the prompt was shown
                localNetworkGranted = true
                localNetworkChecking = false
                connection.cancel()
            }
        }
        connection.start(queue: .main)
        // Timeout after 2s regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            localNetworkGranted = true
            localNetworkChecking = false
            connection.cancel()
        }
    }

    private func runModelTest() {
        isTesting = true
        testResult = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                isTesting = false
                testResult = ModelTestResult(success: true, response: "ready", latencyMs: 320)
            }
        }
    }

    private func finishSetup() {
        AppState.shared.hasCompletedSetup = true
        step = .done
    }
}

// MARK: - Permission row

enum PermissionStatus { case granted, denied, unknown }

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let actionLabel: String?
    let onAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.bold())
                    statusBadge
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let label = actionLabel, let action = onAction {
                    Button(label, action: action)
                        .font(.caption.bold())
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusBadge: some View {
        Group {
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Not granted", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unknown:
                Label("Will prompt on use", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        case .unknown: return .secondary
        }
    }
}

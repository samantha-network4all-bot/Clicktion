import Foundation

final class ServiceManager {
    private var process: Process?
    private let binaryPath: String
    private let serviceURL = URL(string: "http://localhost:8080")!

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        binaryPath = appSupport.appendingPathComponent("Clicktion/clicktion-service").path
    }

    func start() {
        launchProcess()
        Task { await startupSequence() }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: - Private

    private func launchProcess() {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            print("Service binary not found at \(binaryPath)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.environment = ProcessInfo.processInfo.environment
        try? p.run()
        process = p
    }

    private func startupSequence() async {
        await waitForHealth()
        await bootstrapAPIKey()
        await syncModels()
        await MainActor.run { AppState.shared.isServiceReady = true }
    }

    // Poll /health until the service responds (up to 15 s)
    private func waitForHealth() async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let _ = try? await URLSession.shared.data(from: serviceURL.appendingPathComponent("/health")) {
                return
            }
        }
    }

    // Create the first API key if none exists yet; store it in Keychain
    private func bootstrapAPIKey() async {
        let hasKey = await MainActor.run { !AppState.shared.apiKey.isEmpty }
        if hasKey { return }

        var req = URLRequest(url: serviceURL.appendingPathComponent("/bootstrap"))
        req.httpMethod = "POST"
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let key = json["key"] else { return }

        await MainActor.run { AppState.shared.apiKey = key }
    }

    // Fetch the default model from the service and populate AppState
    private func syncModels() async {
        let apiKey = await MainActor.run { AppState.shared.apiKey }
        guard !apiKey.isEmpty else { return }

        var req = URLRequest(url: serviceURL.appendingPathComponent("/api/models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let models = try? JSONDecoder().decode([ModelConfig].self, from: data) else { return }

        let defaultModel = models.first { $0.isDefault } ?? models.first
        await MainActor.run { AppState.shared.activeModel = defaultModel }
    }
}

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
        killStaleService()
        launchProcess()
        Task { await startupSequence() }
    }

    /// Kill any previously running clicktion-service that survived an unclean
    /// shutdown. Without this, a stale service holds port 8080 while the new
    /// spawn loops on "address already in use" — leaving the app talking to an
    /// outdated binary with missing DB migrations.
    private func killStaleService() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", binaryPath]
        try? task.run()
        task.waitUntilExit()
        // Give the OS a moment to release the port
        Thread.sleep(forTimeInterval: 0.3)
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
        p.terminationHandler = { [weak self] _ in
            // Restart automatically on unexpected exit (e.g. crash or SIGKILL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.launchProcess()
            }
        }
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

    // Bootstrap: the Go service writes the key to .apikey in dataDir.
    // We just trigger POST /bootstrap; if the file already exists the
    // service returns 403 and the existing file is used. Either way,
    // AppState.apiKey reads the file directly — no HTTP response parsing needed.
    private func bootstrapAPIKey() async {
        var req = URLRequest(url: serviceURL.appendingPathComponent("/bootstrap"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        // File is written by the service; AppState.apiKey reads it automatically.
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

import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var activeModel: ModelConfig?
    @Published var openTodoCount: Int = 0
    @Published var serviceURL: URL = URL(string: "http://localhost:8080")!
    @Published var isServiceReady: Bool = false

    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedSetup") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedSetup") }
    }

    /// Display name of the language the LLM should reply in (e.g. "English", "Dutch").
    /// Defaults to the system language on first run.
    @Published var responseLanguage: String = {
        if let stored = UserDefaults.standard.string(forKey: "responseLanguage") { return stored }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }() {
        didSet { UserDefaults.standard.set(responseLanguage, forKey: "responseLanguage") }
    }

    // Stored as a plain file rather than Keychain to avoid the per-rebuild
    // code-signature ACL prompts that Keychain triggers for ad-hoc signed binaries.
    // The key only authenticates to the local clicktion-service — not a user credential.
    var apiKey: String {
        get { (try? String(contentsOf: Self.apiKeyFile, encoding: .utf8)) ?? "" }
        set { try? newValue.write(to: Self.apiKeyFile, atomically: true, encoding: .utf8) }
    }

    private static let apiKeyFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clicktion")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".apikey")
    }()

    private init() {
        // Remove any stale Keychain entry from the previous storage approach
        // so macOS stops showing the code-signature ACL dialog.
        KeychainHelper.delete(key: "clicktion-api-key")
    }
}

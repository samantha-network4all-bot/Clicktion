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

    /// Stored selection: either `"system"` (follow system locale) or a language display name.
    @Published var responseLanguage: String =
        UserDefaults.standard.string(forKey: "responseLanguage") ?? "system" {
        didSet { UserDefaults.standard.set(responseLanguage, forKey: "responseLanguage") }
    }

    /// The actual language name sent to the LLM (resolves "system" to the current locale).
    var effectiveResponseLanguage: String {
        responseLanguage == "system" ? Self.systemLanguageName : responseLanguage
    }

    static let systemLanguageName: String = {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }()

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

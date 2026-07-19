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

    // MARK: - Privacy mode

    enum PrivacyMode: String {
        case privateOnly   = "private_only"
        case publicEnabled = "public_enabled"
    }

    @Published var privacyMode: PrivacyMode = {
        let raw = UserDefaults.standard.string(forKey: "privacyMode") ?? ""
        return PrivacyMode(rawValue: raw) ?? .privateOnly
    }() {
        didSet { UserDefaults.standard.set(privacyMode.rawValue, forKey: "privacyMode") }
    }

    // MARK: - Model profiles

    struct ModelProfile: Codable, Equatable {
        var systemPrompt: String
        var thinkingEnabled: Bool
        var maxTokens: Int      // 0 = model default
        var temperature: Double // -1 = model default

        static let thinkingDefault = ModelProfile(
            systemPrompt: "Take your time to reason through the problem carefully before answering.",
            thinkingEnabled: true,
            maxTokens: 0,
            temperature: -1
        )
        static let nonThinkingDefault = ModelProfile(
            systemPrompt: """
                Be direct and concise. Do not explain your reasoning or include thinking steps. \
                Give the answer immediately without preamble. \
                Do not start with phrases like "I'll analyze" or "Let me think". \
                Do not include a thinking or reasoning section.
                """,
            thinkingEnabled: false,
            maxTokens: 2048,
            temperature: 0.3
        )
    }

    @Published var thinkingProfile: ModelProfile = {
        guard let data = UserDefaults.standard.data(forKey: "thinkingProfile"),
              let p = try? JSONDecoder().decode(ModelProfile.self, from: data) else {
            return .thinkingDefault
        }
        return p
    }() { didSet { saveProfile(thinkingProfile, key: "thinkingProfile") } }

    @Published var nonThinkingProfile: ModelProfile = {
        guard let data = UserDefaults.standard.data(forKey: "nonThinkingProfile"),
              let p = try? JSONDecoder().decode(ModelProfile.self, from: data) else {
            return .nonThinkingDefault
        }
        return p
    }() { didSet { saveProfile(nonThinkingProfile, key: "nonThinkingProfile") } }

    private func saveProfile(_ profile: ModelProfile, key: String) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Disk usage

    /// Soft cap on the captures directory in megabytes. The server prunes
    /// oldest images down to this limit after each new capture.
    @Published var maxDiskUsageMB: Int = {
        let v = UserDefaults.standard.integer(forKey: "maxDiskUsageMB")
        return v > 0 ? v : 250
    }() {
        didSet { UserDefaults.standard.set(maxDiskUsageMB, forKey: "maxDiskUsageMB") }
    }

    // MARK: - Language

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

    // MARK: - Parakeet (speech-to-text)

    @Published var parakeetLanguage: String =
        UserDefaults.standard.string(forKey: "parakeetLanguage") ?? "system" {
        didSet { UserDefaults.standard.set(parakeetLanguage, forKey: "parakeetLanguage") }
    }

    /// Language hint passed to Parakeet (v3 script-aware filtering).
    /// `nil` means auto-detect: either the user picked "system" and the current
    /// locale isn't one we map, or they explicitly want auto.
    var parakeetLanguageHint: String? {
        switch parakeetLanguage {
        case "system":
            // Resolve the system locale to a language code Parakeet understands;
            // fall back to auto-detect when it's not one we recognise.
            let code = Locale.current.language.languageCode?.identifier ?? ""
            return ["nl", "en"].contains(code) ? code : nil
        case let code where !code.isEmpty:
            return code
        default:
            return nil
        }
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

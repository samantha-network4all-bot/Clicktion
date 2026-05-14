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

    var apiKey: String {
        get { KeychainHelper.load(key: "clicktion-api-key") ?? "" }
        set { KeychainHelper.save(key: "clicktion-api-key", value: newValue) }
    }

    private init() {}
}

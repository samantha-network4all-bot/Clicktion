import Foundation

struct ModelConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var modelName: String
    var isLocal: Bool
    var isDefault: Bool
    var fallbackOrder: Int

    var isLocalOverride: Bool?

    var effectivelyLocal: Bool {
        if let override = isLocalOverride { return override }
        return isLocal
    }

    static func classify(url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host else { return false }
        let local = ["localhost", "127.0.0.1", "::1"]
        if local.contains(host) { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case baseURL = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
        case isLocal = "is_local"
        case isDefault = "is_default"
        case fallbackOrder = "fallback_order"
        case isLocalOverride = "is_local_override"
    }
}

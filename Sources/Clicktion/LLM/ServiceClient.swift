import Foundation

@MainActor
final class ServiceClient {
    static let shared = ServiceClient()

    private var baseURL: URL { AppState.shared.serviceURL }
    private var apiKey: String { AppState.shared.apiKey }

    private init() {}

    // MARK: - Models

    func fetchModels() async throws -> [ModelConfig] {
        try await get("/api/models")
    }

    func saveModel(_ model: ModelConfig) async throws -> ModelConfig {
        try await post("/api/models", body: model)
    }

    func deleteModel(id: UUID) async throws {
        try await delete("/api/models/\(id.uuidString)")
    }

    func testModel(id: UUID) async throws -> ModelTestResult {
        try await post("/api/models/\(id.uuidString)/test", body: EmptyBody())
    }

    /// Sets the given model as default and returns the refreshed list with is_default updated.
    @discardableResult
    func setDefaultModel(id: UUID) async throws -> [ModelConfig] {
        try await post("/api/models/\(id.uuidString)/setdefault", body: EmptyBody())
    }

    // MARK: - Captures

    func submitCapture(_ payload: CapturePayload) async throws -> CaptureRecord {
        try await post("/api/captures", body: payload)
    }

    func streamJob(id: String, onToken: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/jobs/\(id)/stream"),
                                 timeoutInterval: .infinity)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        // SSE events may span multiple data: lines (sseEscape splits \n into
        // consecutive data: lines). Accumulate them before dispatching.
        var pending = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let chunk = String(line.dropFirst(6))
                if chunk == "[DONE]" {
                    if !pending.isEmpty { onToken(pending); pending = "" }
                    break
                }
                pending = pending.isEmpty ? chunk : pending + "\n" + chunk
            } else if line.isEmpty, !pending.isEmpty {
                onToken(pending)
                pending = ""
            }
        }
    }

    func startJob(captureID: String, skill: Skill, sendImage: Bool? = nil) async throws -> JobRecord {
        struct Body: Encodable {
            let captureID: String
            let skillName: String
            let skillPrompt: String
            let sendImage: Bool
            enum CodingKeys: String, CodingKey {
                case captureID = "capture_id"
                case skillName = "skill_name"
                case skillPrompt = "skill_prompt"
                case sendImage = "send_image"
            }
        }
        let language = AppState.shared.effectiveResponseLanguage
        let prompt = skill.systemPrompt + "\n- You need to reply in \(language)."
        return try await post("/api/jobs", body: Body(
            captureID: captureID,
            skillName: skill.name,
            skillPrompt: prompt,
            sendImage: sendImage ?? (skill.inputMode == .imageAndText)
        ))
    }

    func sendMessage(jobID: String, message: String) async throws {
        struct Body: Encodable { let message: String }
        let _: EmptyResponse = try await post("/api/jobs/\(jobID)/messages", body: Body(message: message))
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ServiceError.httpError(http.statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func delete(_ path: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}
}

enum ServiceError: LocalizedError {
    case httpError(Int, String)
    var errorDescription: String? {
        if case .httpError(let code, let body) = self {
            return "Service error \(code): \(body)"
        }
        return nil
    }
}

struct ModelTestResult: Decodable {
    let success: Bool
    let response: String?
    let latencyMs: Int
    enum CodingKeys: String, CodingKey {
        case success, response
        case latencyMs = "latency_ms"
    }
}

struct SkillInfo: Encodable {
    let name: String
    let triggers: [String]
}

struct CapturePayload: Encodable {
    let imageBase64: String
    let ocrText: String
    let appName: String?
    let windowTitle: String?
    let isPrivate: Bool
    let availableSkills: [SkillInfo]
    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case ocrText = "ocr_text"
        case appName = "app_name"
        case windowTitle = "window_title"
        case isPrivate = "is_private"
        case availableSkills = "available_skills"
    }
}

struct CaptureRecord: Decodable {
    let id: String
    let suggestedSkill: String?
    enum CodingKeys: String, CodingKey {
        case id
        case suggestedSkill = "suggested_skill"
    }
}

struct JobRecord: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id }
}

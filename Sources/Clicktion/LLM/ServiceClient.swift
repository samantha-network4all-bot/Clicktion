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

    /// Flip an existing capture's is_todo flag (called when the user picks
    /// "Todo" in the dialog after the capture has already been submitted for
    /// skill suggestion). The server also syncs the linked notebook's flag.
    func markCaptureAsTodo(captureID: String) async throws {
        struct Body: Encodable {
            let isTodo: Bool
            enum CodingKeys: String, CodingKey { case isTodo = "is_todo" }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/captures/\(captureID)"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(isTodo: true))
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ServiceError.httpError(http.statusCode, body)
        }
    }

    // MARK: - Notebook counts

    /// Returns the number of open todos (notebooks with is_todo=1 AND todo_done=0).
    /// Drives the menu-bar badge.
    func fetchOpenTodoCount() async throws -> Int {
        struct Reply: Decodable {
            let openTodos: Int
            enum CodingKeys: String, CodingKey { case openTodos = "open_todos" }
        }
        let r: Reply = try await get("/api/notebooks/count")
        return r.openTodos
    }

    // MARK: - Storage

    /// Fire-and-forget prune. The server walks oldest captures first,
    /// deleting images (or the whole record if OCR is empty) until the
    /// captures directory shrinks below maxMB.
    func pruneStorage(maxMB: Int) async {
        struct Body: Encodable {
            let maxBytes: Int64
            enum CodingKeys: String, CodingKey { case maxBytes = "max_bytes" }
        }
        struct Reply: Decodable {}
        let _: Reply? = try? await post("/api/storage/prune",
                                        body: Body(maxBytes: Int64(maxMB) * 1024 * 1024))
    }

    // Parses SSE byte-by-byte rather than via .lines because
    // URLSession.AsyncBytes.AsyncLineSequence silently drops empty lines —
    // which destroys SSE event boundaries (data: \n\n) and causes every
    // token to accumulate into a single dispatch at [DONE].
    func streamJob(id: String, onToken: @escaping (String) async -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/jobs/\(id)/stream"),
                                 timeoutInterval: .infinity)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, _) = try await URLSession.shared.bytes(for: request)

        var lineBuf: [UInt8] = []
        var dataLines: [String] = []

        func dispatchEvent() async {
            guard !dataLines.isEmpty else { return }
            let token = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            if token == "[DONE]" { return }
            await onToken(token)
        }

        for try await byte in bytes {
            if byte == 0x0A { // newline
                let line = String(decoding: lineBuf, as: UTF8.self)
                lineBuf.removeAll(keepingCapacity: true)
                if line.isEmpty {
                    await dispatchEvent()
                } else if line.hasPrefix("data: ") {
                    dataLines.append(String(line.dropFirst(6)))
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)))
                }
                // Ignore comment lines (start with :) and other field types.
            } else if byte != 0x0D { // skip \r
                lineBuf.append(byte)
            }
        }
        await dispatchEvent()
    }

    func startJob(captureID: String, skill: Skill, inputMode: Skill.InputMode? = nil,
                  useThinkingProfile: Bool = true,
                  fresh: Bool = false) async throws -> JobRecord {
        struct Body: Encodable {
            let captureID: String
            let skillName: String
            let skillPrompt: String
            let sendImage: Bool
            let sendOCR: Bool
            let masterPrompt: String
            let temperature: Double
            let maxTokens: Int
            let thinkingEnabled: Bool
            let fresh: Bool
            enum CodingKeys: String, CodingKey {
                case captureID = "capture_id"
                case skillName = "skill_name"
                case skillPrompt = "skill_prompt"
                case sendImage = "send_image"
                case sendOCR = "send_ocr"
                case masterPrompt = "master_prompt"
                case temperature
                case maxTokens = "max_tokens"
                case thinkingEnabled = "thinking_enabled"
                case fresh
            }
        }
        let language = AppState.shared.effectiveResponseLanguage
        let prompt = skill.systemPrompt + "\n- You need to reply in \(language)."
        let profile = useThinkingProfile
            ? AppState.shared.thinkingProfile
            : AppState.shared.nonThinkingProfile
        let mode = inputMode ?? skill.inputMode
        return try await post("/api/jobs", body: Body(
            captureID: captureID,
            skillName: skill.name,
            skillPrompt: prompt,
            sendImage: mode.sendImage,
            sendOCR: mode.sendOCR,
            masterPrompt: profile.systemPrompt,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            thinkingEnabled: profile.thinkingEnabled,
            fresh: fresh
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
    let isTodo: Bool
    let availableSkills: [SkillInfo]
    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case ocrText = "ocr_text"
        case appName = "app_name"
        case windowTitle = "window_title"
        case isPrivate = "is_private"
        case isTodo = "is_todo"
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

import Foundation

/// A chat message with tool-calling fields (OpenAI-compatible).
struct AgentMessage: Codable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var name: String?

    init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil,
         toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    // Omit nil fields so picky endpoints (Ollama) don't see `tool_calls: null`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

/// A function call requested by the model.
struct ToolCall: Codable, Identifiable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String   // JSON-encoded arguments

        /// Parses `arguments` into a dictionary (empty on failure).
        func parsedArguments() -> [String: Any] {
            guard let data = arguments.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return obj
        }
    }
}

/// One assistant turn: free text and/or tool calls.
struct AgentTurn: Codable {
    let content: String
    let toolCalls: [ToolCall]

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        toolCalls = (try? c.decode([ToolCall].self, forKey: .toolCalls)) ?? []
    }
}

/// An OpenAI-compatible function tool definition.
struct AgentTool: Encodable {
    let type = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: AnyEncodable   // JSON schema object
    }

    init(name: String, description: String, parameters: [String: Any]) {
        function = Function(name: name, description: description,
                            parameters: AnyEncodable(parameters))
    }
}

/// Encodes arbitrary JSON-compatible values (used for tool parameter schemas).
struct AnyEncodable: Encodable {
    private let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as [Any]: try container.encode(v.map(AnyEncodable.init))
        case let v as [String: Any]: try container.encode(v.mapValues(AnyEncodable.init))
        default: try container.encodeNil()
        }
    }
}

import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool = false

    enum Role { case user, assistant }

    // Parsed segments for rendering — recomputed from content
    var segments: [Segment] {
        Self.parse(content)
    }

    enum Segment {
        case text(String)
        case code(language: String?, body: String)
    }

    // Split content on fenced code blocks (``` ... ```)
    private static func parse(_ raw: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = raw[raw.startIndex...]
        let fence = "```"

        while !rest.isEmpty {
            if let openRange = rest.range(of: fence) {
                let before = String(rest[rest.startIndex..<openRange.lowerBound])
                if !before.isEmpty { segments.append(.text(before)) }

                let afterOpen = rest[openRange.upperBound...]
                // Extract optional language tag on same line as opening fence
                let lang: String?
                let codeStart: String.Index
                if let nl = afterOpen.firstIndex(of: "\n") {
                    let tag = String(afterOpen[afterOpen.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
                    lang = tag.isEmpty ? nil : tag
                    codeStart = afterOpen.index(after: nl)
                } else {
                    lang = nil
                    codeStart = afterOpen.startIndex
                }

                let codeRegion = afterOpen[codeStart...]
                if let closeRange = codeRegion.range(of: fence) {
                    let body = String(codeRegion[codeRegion.startIndex..<closeRange.lowerBound])
                    segments.append(.code(language: lang, body: body))
                    rest = codeRegion[closeRange.upperBound...]
                } else {
                    // Unclosed fence — treat remainder as text
                    segments.append(.text(String(afterOpen)))
                    break
                }
            } else {
                segments.append(.text(String(rest)))
                break
            }
        }

        return segments.filter {
            if case .text(let s) = $0 { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }
}

extension ChatMessage {
    static func user(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, content: text)
    }

    static func assistantStreaming() -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, content: "", isStreaming: true)
    }
}

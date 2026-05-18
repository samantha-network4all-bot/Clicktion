import Foundation

struct Skill: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var triggers: [String]
    var systemPrompt: String
    var security: SkillSecurity
    var filename: String
    var inputMode: InputMode = .imageAndText

    init(id: UUID = UUID(), name: String, icon: String, triggers: [String],
         systemPrompt: String, security: SkillSecurity, filename: String,
         inputMode: InputMode = .imageAndText) {
        self.id = id
        self.name = name
        self.icon = icon
        self.triggers = triggers
        self.systemPrompt = systemPrompt
        self.security = security
        self.filename = filename
        self.inputMode = inputMode
    }

    enum InputMode: String, Codable, CaseIterable, Hashable {
        case imageAndText = "image_and_text"
        case textOnly = "text_only"

        var displayName: String {
            switch self {
            case .imageAndText: return "Image + OCR text"
            case .textOnly:     return "OCR text only"
            }
        }

        var icon: String {
            switch self {
            case .imageAndText: return "photo.badge.checkmark"
            case .textOnly:     return "doc.text"
            }
        }
    }
}

struct SkillSecurity: Codable, Hashable {
    var allowCLI: Bool
    var allowFileWrite: Bool
    var allowNetwork: Bool
    var skipConfirmation: Bool
    var blocklist: [String]

    static let safe = SkillSecurity(
        allowCLI: false,
        allowFileWrite: false,
        allowNetwork: false,
        skipConfirmation: false,
        blocklist: []
    )

    enum CodingKeys: String, CodingKey {
        case allowCLI = "allow_cli"
        case allowFileWrite = "allow_file_write"
        case allowNetwork = "allow_network"
        case skipConfirmation = "skip_confirmation"
        case blocklist
    }
}

import Foundation

@MainActor
final class SkillLoader {
    static let shared = SkillLoader()

    private let skillsDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        skillsDirectory = appSupport.appendingPathComponent("Clicktion/skills")
        ensureSkillsDirectory()
    }

    func loadAll() throws -> [Skill] {
        let mdFiles = try FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }

        return mdFiles.compactMap { mdURL in
            try? load(from: mdURL)
        }.sorted { $0.name < $1.name }
    }

    func load(from mdURL: URL) throws -> Skill {
        let raw = try String(contentsOf: mdURL, encoding: .utf8)
        let (frontmatter, body) = parseFrontmatter(raw)

        let jsonURL = mdURL.deletingPathExtension().appendingPathExtension("json")
        let security: SkillSecurity
        if let data = try? Data(contentsOf: jsonURL) {
            security = (try? JSONDecoder().decode(SkillSecurity.self, from: data)) ?? .safe
        } else {
            security = .safe
        }

        let inputMode = frontmatter["input_mode"].flatMap { Skill.InputMode(rawValue: $0) } ?? .imageAndText

        return Skill(
            name: frontmatter["name"] ?? mdURL.deletingPathExtension().lastPathComponent,
            icon: frontmatter["icon"] ?? "sparkles",
            triggers: frontmatter["triggers"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            systemPrompt: body,
            security: security,
            filename: mdURL.deletingPathExtension().lastPathComponent,
            inputMode: inputMode
        )
    }

    func save(_ skill: Skill) throws {
        let mdURL = skillsDirectory.appendingPathComponent("\(skill.filename).md")
        let jsonURL = skillsDirectory.appendingPathComponent("\(skill.filename).json")

        let mdContent = """
        ---
        name: \(skill.name)
        icon: \(skill.icon)
        triggers: \(skill.triggers.joined(separator: ", "))
        input_mode: \(skill.inputMode.rawValue)
        ---

        \(skill.systemPrompt)
        """
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)

        let jsonData = try JSONEncoder().encode(skill.security)
        try jsonData.write(to: jsonURL)
    }

    private func parseFrontmatter(_ raw: String) -> ([String: String], String) {
        var frontmatter: [String: String] = [:]
        var body = raw

        guard raw.hasPrefix("---") else { return (frontmatter, body) }
        let lines = raw.components(separatedBy: "\n")
        var endIndex = 0
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = i
                break
            }
            let parts = lines[i].split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { frontmatter[parts[0]] = parts[1] }
        }
        body = lines.dropFirst(endIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatter, body)
    }

    func delete(_ skill: Skill) throws {
        let md   = skillsDirectory.appendingPathComponent("\(skill.filename).md")
        let json = skillsDirectory.appendingPathComponent("\(skill.filename).json")
        try FileManager.default.removeItem(at: md)
        try? FileManager.default.removeItem(at: json)
    }

    func filenameFor(name: String, existing: [Skill]) -> String {
        var slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if slug.isEmpty { slug = "skill" }
        // Ensure uniqueness
        let taken = Set(existing.map(\.filename))
        var candidate = slug
        var counter = 2
        while taken.contains(candidate) { candidate = "\(slug)-\(counter)"; counter += 1 }
        return candidate
    }

    private func ensureSkillsDirectory() {
        try? FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
    }
}

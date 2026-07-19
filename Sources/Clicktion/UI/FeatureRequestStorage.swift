import Foundation

actor FeatureRequestStorage {
    static let shared = FeatureRequestStorage()

    private var featuresDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clicktion/features")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func save(title: String, description: String) throws -> Int {
        let number = nextNumber()
        let content = """
            # \(title)

            **Feature request — reg-\(String(format: "%04d", number))**

            ---

            \(description)

            ---
            _Submitted on \(Date.now.formatted(date: .long, time: .shortened))_
            """

        let url = featuresDir.appendingPathComponent("feature-reg-\(String(format: "%04d", number)).md")
        try content.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        return number
    }

    private func nextNumber() -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: featuresDir, includingPropertiesForKeys: nil)) ?? []
        let existing = urls.compactMap { url -> Int? in
            let name = url.lastPathComponent
            let pattern = #"feature-reg-(\d{4})\.md"#
            guard let range = name.range(of: pattern, options: String.CompareOptions.regularExpression) else { return nil }
            let digits = name[range].filter(\.isNumber)
            return Int(digits)
        }
        return (existing.max() ?? 0) + 1
    }
}

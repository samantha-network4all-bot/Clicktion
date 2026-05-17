import SwiftUI

@MainActor
final class SkillEditorViewModel: ObservableObject {
    @Published var skills: [Skill] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?

    // Pending selection when user has unsaved changes
    var pendingSelectionID: UUID?

    var selected: Skill? {
        skills.first { $0.id == selectedID }
    }

    func load() {
        do {
            skills = try SkillLoader.shared.loadAll()
            if selectedID == nil { selectedID = skills.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ skill: Skill) {
        do {
            try SkillLoader.shared.save(skill)
            if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[idx] = skill
            } else {
                skills.append(skill)
                persistOrder()
            }
            selectedID = skill.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ skill: Skill) {
        do {
            try SkillLoader.shared.delete(skill)
            skills.removeAll { $0.id == skill.id }
            selectedID = skills.first?.id
            persistOrder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        skills.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    private func persistOrder() {
        SkillLoader.shared.saveOrder(skills.map(\.filename))
    }

    func newSkill() -> Skill {
        Skill(
            name: "New Skill",
            icon: "sparkles",
            triggers: [],
            systemPrompt: "You are analyzing a screenshot.\n\n",
            security: .safe,
            filename: SkillLoader.shared.filenameFor(name: "New Skill", existing: skills)
        )
    }
}

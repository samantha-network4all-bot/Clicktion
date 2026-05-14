import SwiftUI

struct SkillEditorView: View {
    @StateObject private var vm = SkillEditorViewModel()
    @State private var showDiscardAlert = false
    @State private var detailHasChanges = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let skill = vm.selected {
                SkillDetailView(
                    skill: skill,
                    hasChanges: $detailHasChanges,
                    onSave: { updated in
                        vm.save(updated)
                        detailHasChanges = false
                    },
                    onDelete: {
                        vm.delete(skill)
                        detailHasChanges = false
                    }
                )
                .id(skill.id) // force re-init when selection changes
            } else {
                emptyDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 520)
        .onAppear { vm.load() }
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                if let id = vm.pendingSelectionID {
                    vm.selectedID = id
                    detailHasChanges = false
                }
                vm.pendingSelectionID = nil
            }
            Button("Keep Editing", role: .cancel) {
                vm.pendingSelectionID = nil
            }
        } message: {
            Text("You have unsaved changes. Discard them and switch skills?")
        }
        .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(vm.skills, selection: $vm.selectedID) { skill in
            SkillRowView(skill: skill)
                .tag(skill.id)
                .onTapGesture { switchTo(skill.id) }
        }
        .listStyle(.sidebar)
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addSkill()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New skill")
            }
        }
        .onChange(of: vm.selectedID) { old, new in
            // If user clicked a different row while detail has changes,
            // revert selection and show alert
            if detailHasChanges, let newID = new, newID != old {
                vm.selectedID = old
                vm.pendingSelectionID = newID
                showDiscardAlert = true
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a skill to edit, or add a new one.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func switchTo(_ id: UUID) {
        if detailHasChanges && id != vm.selectedID {
            vm.pendingSelectionID = id
            showDiscardAlert = true
        } else {
            vm.selectedID = id
        }
    }

    private func addSkill() {
        if detailHasChanges {
            vm.pendingSelectionID = nil
            showDiscardAlert = true
            return
        }
        let skill = vm.newSkill()
        vm.skills.insert(skill, at: 0)
        vm.selectedID = skill.id
        detailHasChanges = true
    }
}

// MARK: - Sidebar row

struct SkillRowView: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: skill.icon)
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body)
                if !skill.triggers.isEmpty {
                    Text(skill.triggers.prefix(3).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if skill.security.dangerLevel != .none {
                dangerBadge(skill.security.dangerLevel)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func dangerBadge(_ level: SkillSecurity.DangerLevel) -> some View {
        Text(level.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(dangerColor(level).opacity(0.12))
            .foregroundStyle(dangerColor(level))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func dangerColor(_ level: SkillSecurity.DangerLevel) -> Color {
        switch level {
        case .none:   return .clear
        case .low:    return .blue
        case .medium: return .orange
        case .high:   return .red
        }
    }
}

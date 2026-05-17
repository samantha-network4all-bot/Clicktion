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
        .frame(minWidth: 860, minHeight: 520)
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
        List(selection: $vm.selectedID) {
            ForEach(vm.skills) { skill in
                SkillRowView(skill: skill)
                    .tag(skill.id)
                    .onTapGesture { switchTo(skill.id) }
            }
            .onMove { from, to in
                vm.move(from: from, to: to)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
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
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Image(systemName: skill.icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(skill.name).font(.body)
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI

struct SkillDetailView: View {
    @State private var draft: Skill
    @Binding var hasChanges: Bool
    var onSave: (Skill) -> Void
    var onDelete: () -> Void

    @State private var triggersText: String
    @State private var showDeleteConfirm = false
    @FocusState private var promptFocused: Bool

    init(skill: Skill, hasChanges: Binding<Bool>, onSave: @escaping (Skill) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: skill)
        _hasChanges = hasChanges
        _triggersText = State(initialValue: skill.triggers.joined(separator: ", "))
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identitySection
                Divider().padding(.vertical, 20)
                promptSection
                Divider().padding(.vertical, 20)
                actionRow
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft) { _, _ in hasChanges = true }
        .onChange(of: triggersText) { _, new in
            draft.triggers = new.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            hasChanges = true
        }
        .confirmationDialog("Delete \"\(draft.name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Skill", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The skill file will be permanently removed from disk.")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Identity", icon: "tag")

            VStack(alignment: .leading, spacing: 6) {
                Label("Name", systemImage: "textformat").font(.caption).foregroundStyle(.secondary)
                TextField("Skill name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Send to LLM", systemImage: "square.and.arrow.up")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draft.inputMode) {
                    ForEach(Skill.InputMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(draft.inputMode == .textOnly
                     ? "The screenshot will not be sent — useful for text-only models or to save tokens."
                     : "Both the screenshot and OCR text are sent to the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Prompt editor

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "System Prompt", icon: "text.alignleft")
                Spacer()
                Text("\(draft.systemPrompt.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft.systemPrompt)
                .focused($promptFocused)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200, maxHeight: 400)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                    promptFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Skill", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            Spacer()

            if hasChanges {
                Button("Discard") {
                    // Caller handles by re-init via .id(skill.id)
                    hasChanges = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Button("Save") {
                onSave(draft)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasChanges)
        }
    }

}

// MARK: - Supporting views

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

struct TriggerChipsView: View {
    let triggers: [String]

    var body: some View {
        // Simple wrapping row using a horizontal flow
        HStack(spacing: 6) {
            ForEach(triggers.prefix(8), id: \.self) { trigger in
                Text(trigger)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            if triggers.count > 8 {
                Text("+\(triggers.count - 8) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

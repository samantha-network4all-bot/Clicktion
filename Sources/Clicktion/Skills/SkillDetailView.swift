import SwiftUI
import LocalAuthentication

struct SkillDetailView: View {
    @State private var draft: Skill
    @Binding var hasChanges: Bool
    var onSave: (Skill) -> Void
    var onDelete: () -> Void

    @State private var triggersText: String
    @State private var showDeleteConfirm = false
    @State private var newBlocklistItem = ""
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
                securitySection
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

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Security", icon: "lock.shield")

            dangerLevelRow

            Divider()

            permissionToggles

            if !draft.security.blocklist.isEmpty || draft.security.allowCLI {
                Divider()
                blocklistSection
            }
        }
    }

    private var dangerLevelRow: some View {
        HStack {
            Label("Danger level", systemImage: "exclamationmark.triangle")
                .font(.callout)
            Spacer()
            Picker("", selection: $draft.security.dangerLevel) {
                ForEach(SkillSecurity.DangerLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
    }

    private var permissionToggles: some View {
        VStack(spacing: 10) {
            PermissionToggle(
                label: "Allow CLI execution",
                icon: "terminal",
                description: "Skill can suggest and run shell commands.",
                isOn: $draft.security.allowCLI
            )
            PermissionToggle(
                label: "Allow file writes",
                icon: "doc.badge.plus",
                description: "Skill can write or modify files on disk.",
                isOn: $draft.security.allowFileWrite
            )
            PermissionToggle(
                label: "Allow network access",
                icon: "network",
                description: "Skill can make outbound network calls.",
                isOn: $draft.security.allowNetwork
            )
            skipConfirmationToggle
        }
    }

    private var skipConfirmationToggle: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Skip confirmation for dangerous actions")
                    .font(.callout)
                Text("Actions run without asking the user. Requires authentication to enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { draft.security.skipConfirmation },
                set: { newValue in
                    if newValue {
                        // Require biometric/password to enable
                        Task { @MainActor in
                            let ok = await authenticate(reason: "Enabling skip_confirmation allows commands to run without user confirmation.")
                            if ok { draft.security.skipConfirmation = true }
                        }
                    } else {
                        draft.security.skipConfirmation = false
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(12)
        .background(draft.security.skipConfirmation
                    ? Color.red.opacity(0.06)
                    : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(draft.security.skipConfirmation ? Color.red.opacity(0.3) : Color.clear))
    }

    private var blocklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Command blocklist", systemImage: "nosign")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(draft.security.blocklist.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    TextField("rm -rf", text: $draft.security.blocklist[idx])
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        draft.security.blocklist.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("Add blocked pattern…", text: $newBlocklistItem)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addBlocklistItem() }
                Button("Add") { addBlocklistItem() }
                    .disabled(newBlocklistItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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

    // MARK: - Helpers

    private func addBlocklistItem() {
        let item = newBlocklistItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        draft.security.blocklist.append(item)
        newBlocklistItem = ""
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true // No auth hardware — allow
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)) ?? false
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

struct PermissionToggle: View {
    let label: String
    let icon: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

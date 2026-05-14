import SwiftUI

struct CaptureDialogView: View {
    @StateObject var vm: CaptureDialogViewModel
    var onSend: (String?, Skill?) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            thumbnailSection
            Divider()
            ocrSection
            Divider()
            controlsSection
        }
        .frame(width: 560)
        .onAppear { vm.onAppear() }
    }

    // MARK: - Thumbnail

    private var thumbnailSection: some View {
        Image(nsImage: vm.capture.image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 560, maxHeight: 280)
            .background(Color.black)
    }

    // MARK: - OCR text

    private var ocrSection: some View {
        ScrollView {
            Group {
                if vm.isOCRRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading text…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else if vm.ocrText.isEmpty {
                    Text("No text detected")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    Text(vm.ocrText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(height: 110)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 12) {
            sourceInfo
            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 16) {
                privacyToggle
                Spacer()
                skillPicker
            }
            actionButtons
        }
        .padding(16)
    }

    private var sourceInfo: some View {
        Group {
            if vm.capture.appName != nil || vm.capture.windowTitle != nil {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    if let app = vm.capture.appName {
                        Text(app).fontWeight(.medium)
                    }
                    if let title = vm.capture.windowTitle {
                        Text("—")
                            .foregroundStyle(.secondary)
                        Text(title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var privacyToggle: some View {
        Toggle(isOn: $vm.isPrivate) {
            Label(
                vm.isPrivate ? "Private" : "Public",
                systemImage: vm.isPrivate ? "lock.fill" : "globe"
            )
            .font(.callout)
        }
        .toggleStyle(.checkbox)
        .help(vm.isPrivate
              ? "Processed by local LLM only. No data leaves your network."
              : "May be processed by a remote LLM.")
    }

    private var skillPicker: some View {
        HStack(spacing: 6) {
            if vm.isSuggestingSkill {
                ProgressView().controlSize(.small)
                Text("Analyzing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Picker("Skill", selection: $vm.selectedSkill) {
                    Text("No skill").tag(Optional<Skill>.none)
                    ForEach(vm.availableSkills) { skill in
                        Label(skill.name, systemImage: skill.icon)
                            .tag(Optional(skill))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button {
                vm.send { jobID, skill in
                    onSend(jobID, skill)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Send")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(vm.isSuggestingSkill || vm.isSending)
        }
    }
}

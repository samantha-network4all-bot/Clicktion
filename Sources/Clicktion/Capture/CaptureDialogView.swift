import SwiftUI

private let kDialogWidth: CGFloat     = 672
private let kDialogHeight: CGFloat    = 580   // fixed — prevents window auto-resize crash
private let kThumbnailHeight: CGFloat = 260
private let kCopySidebar: CGFloat     = 36    // width of the copy-button column beside thumbnail

struct CaptureDialogView: View {
    @StateObject var vm: CaptureDialogViewModel
    var onSend: (String?, Skill?) -> Void
    var onCancel: () -> Void

    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            annotationToolbar
            if vm.capture.appName != nil || vm.capture.windowTitle != nil {
                appNameBar
            }
            thumbnailRow
            Divider()
            ocrSection
            Divider()
            bottomBar
            advancedSection
        }
        .frame(width: kDialogWidth, height: kDialogHeight)
        .onAppear { vm.onAppear() }
    }

    // MARK: - Annotation toolbar (no copy button here)

    private var annotationToolbar: some View {
        HStack(spacing: 8) {
            ToolbarButton(icon: "rectangle.dashed", label: "Select region",
                          isActive: vm.activeTool == .rectangle) {
                vm.activeTool = vm.activeTool == .rectangle ? .none : .rectangle
            }
            ToolbarButton(icon: "pencil.tip", label: "Draw",
                          isActive: vm.activeTool == .freedraw) {
                vm.activeTool = vm.activeTool == .freedraw ? .none : .freedraw
            }
            ToolbarButton(icon: "textformat", label: "Add note",
                          isActive: vm.activeTool == .text) {
                vm.activeTool = vm.activeTool == .text ? .none : .text
            }

            Spacer()

            if !vm.annotations.isEmpty || vm.croppedImage != nil {
                Button { vm.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if vm.croppedImage != nil {
                Text("Region selected").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - App name bar

    private var appNameBar: some View {
        HStack(spacing: 4) {
            if let app = vm.capture.appName { Text(app).fontWeight(.medium) }
            if let title = vm.capture.windowTitle {
                Text("—").foregroundStyle(.secondary)
                Text(title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
    }

    // MARK: - Thumbnail + copy sidebar

    private var thumbnailRow: some View {
        HStack(spacing: 0) {
            // Thumbnail
            ZStack {
                Image(nsImage: vm.effectiveImage)
                    .resizable()
                    .scaledToFit()

                if vm.activeTool != .none || !vm.annotations.isEmpty {
                    AnnotationCanvasView(
                        imageSize: vm.effectiveImage.size,
                        activeTool: $vm.activeTool,
                        annotations: $vm.annotations,
                        onRectFinalized: { vm.rectangleFinalized($0) }
                    )
                }
            }
            .frame(width: kDialogWidth - kCopySidebar, height: kThumbnailHeight)
            .background(Color.black)
            .clipped()
            .overlay(alignment: .bottom) {
                if vm.activeTool == .text { textNoteBar }
            }

            // Copy-image button sidebar
            VStack(spacing: 0) {
                CopyButton(help: "Copy image to clipboard") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([vm.effectiveImage])
                }
                .padding(.top, 8)
                Spacer()
            }
            .frame(width: kCopySidebar, height: kThumbnailHeight)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var textNoteBar: some View {
        HStack(spacing: 8) {
            TextField("Add a markdown note…", text: $vm.textNote)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onSubmit { vm.commitTextAnnotation() }
            Button("Add") { vm.commitTextAnnotation() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.textNote.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - OCR section (below thumbnail, full width)

    private var ocrSection: some View {
        ScrollView {
            Group {
                if vm.isOCRRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading text…").foregroundStyle(.secondary)
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
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            CopyButton(help: "Copy text to clipboard",
                       disabled: vm.ocrText.isEmpty || vm.isOCRRunning) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.ocrText, forType: .string)
            }
            .padding(4)
        }
    }

    // MARK: - Bottom bar: skill picker + Cancel + Action

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if vm.isSuggestingSkill {
                ProgressView().controlSize(.small)
                Text("Analyzing…").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkles").foregroundStyle(.secondary).font(.callout)
                Picker("Skill", selection: $vm.selectedSkill) {
                    Text("No skill").tag(Optional<Skill>.none)
                    ForEach(vm.availableSkills) { skill in
                        Label(skill.name, systemImage: skill.icon).tag(Optional(skill))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 160)
                .onChange(of: vm.selectedSkill) { _, skill in vm.skillDidChange(skill) }
            }

            Spacer()

            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.escape, modifiers: [])

            Button {
                vm.send { jobID, skill in onSend(jobID, skill) }
            } label: {
                HStack(spacing: 4) { Text("Action"); Image(systemName: "arrow.right") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(vm.isSuggestingSkill || vm.isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Advanced section (collapsible)

    private var advancedSection: some View {
        let privateOnly = AppState.shared.privacyMode == .privateOnly
        return VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack(spacing: 16) {
                    if !privateOnly {
                        privacyToggle
                    }
                    Spacer()
                    inputModePicker
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            } label: {
                Text("Advanced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var privacyToggle: some View {
        Toggle(isOn: $vm.isPrivate) {
            Label(vm.isPrivate ? "Private" : "Public",
                  systemImage: vm.isPrivate ? "lock.fill" : "globe")
                .font(.callout)
        }
        .toggleStyle(.checkbox)
        .help(vm.isPrivate
              ? "Processed by local LLM only. No data leaves your network."
              : "May be processed by a remote LLM.")
    }

    private var inputModePicker: some View {
        Picker("", selection: $vm.sendImage) {
            Label("Image + text", systemImage: "photo").tag(true)
            Label("Text only", systemImage: "doc.text").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .padding(6)
                .background(hovering && !disabled ? Color.secondary.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(hovering && !disabled ? Color.primary.opacity(0.75) : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Toolbar button

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

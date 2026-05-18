import SwiftUI

private let kSkillsWidth: CGFloat     = 200   // left sidebar with clickable skills
private let kDialogWidth: CGFloat     = 672   // width of the main content column (right of sidebar)
private let kDialogHeight: CGFloat    = 600   // fixed — prevents window auto-resize crash
private let kThumbnailHeight: CGFloat = 360
private let kCopySidebar: CGFloat     = 36    // width of the copy-button column beside thumbnail
private let kOCRPreviewSentences      = 5     // OCR preview cap; full text still sent to LLM
private let kOCRHeight: CGFloat       = 80    // 50% shorter than the previous flexible OCR pane

struct CaptureDialogView: View {
    @StateObject var vm: CaptureDialogViewModel
    var onSend: (String?, String?, Skill?) -> Void
    var onCancel: () -> Void

    @State private var showAdvanced = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                annotationToolbar
                thumbnailRow
                Divider()
                ocrSection
                Divider()
                bottomBar
                advancedSection
            }
            .frame(width: kDialogWidth)
            Divider()
            skillsSidebar
        }
        .frame(width: kDialogWidth + 1 + kSkillsWidth, height: kDialogHeight)
        .onAppear { vm.onAppear() }
    }

    // MARK: - Skills sidebar

    private var skillsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text("Skills").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if vm.isSuggestingSkill {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(vm.availableSkills) { skill in
                        skillRow(skill)
                    }
                }
                .padding(6)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: kSkillsWidth)
    }

    private func skillRow(_ skill: Skill) -> some View {
        let isSuggested = vm.selectedSkill?.id == skill.id
        return Button {
            triggerSkill(skill)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: skill.icon)
                    .foregroundStyle(isSuggested ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(skill.name)
                    .font(.callout)
                    .foregroundStyle(isSuggested ? Color.accentColor : Color.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if isSuggested {
                    Image(systemName: "sparkle")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .help("Suggested for this capture")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSuggested ? Color.accentColor.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(vm.isSending)
    }

    private func triggerSkill(_ skill: Skill) {
        guard !vm.isSending else { return }
        vm.selectedSkill = skill
        vm.skillDidChange(skill)
        vm.send { jobID, captureID, sk in onSend(jobID, captureID, sk) }
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

    // MARK: - OCR section (label bar + scrollable text below thumbnail)

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ocrHeader
            ocrScroll
        }
    }

    private var ocrHeader: some View {
        HStack {
            Text("Text Captures:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    private var ocrScroll: some View {
        HStack(spacing: 0) {
            ScrollView {
                Group {
                    if vm.isOCRRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading text…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } else if vm.ocrText.isEmpty {
                        Text("No text detected")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        let (preview, hiddenCount) = firstSentences(vm.ocrText, limit: kOCRPreviewSentences)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if hiddenCount > 0 {
                                Text("+ \(hiddenCount) more sentence\(hiddenCount == 1 ? "" : "s") (full text is sent to the LLM)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(width: kDialogWidth - kCopySidebar, height: kOCRHeight)
            .background(Color(nsColor: .textBackgroundColor))

            // Copy column — mirrors the thumbnail's copy sidebar layout.
            VStack(spacing: 0) {
                CopyButton(help: "Copy text to clipboard",
                           disabled: vm.ocrText.isEmpty || vm.isOCRRunning) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.ocrText, forType: .string)
                }
                .padding(.top, 6)
                Spacer()
            }
            .frame(width: kCopySidebar, height: kOCRHeight)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Bottom bar: skill picker + Cancel + Action

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if vm.isSending {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Click a skill to run").font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.escape, modifiers: [])
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
                VStack(alignment: .leading, spacing: 10) {
                    // Profile picker
                    HStack(spacing: 8) {
                        Text("Profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $vm.useThinkingProfile) {
                            Label("Thinking", systemImage: "brain").tag(true)
                            Label("Direct", systemImage: "bolt").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    HStack(spacing: 16) {
                        if !privateOnly {
                            privacyToggle
                        }
                        Spacer()
                        inputModePicker
                    }
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

// MARK: - Sentence preview helper

/// Returns the first `limit` sentences of `text` plus the count of remaining
/// sentences. Sentence boundaries use NaturalLanguage's tokenizer so it
/// handles punctuation, line breaks and Unicode terminators correctly.
private func firstSentences(_ text: String, limit: Int) -> (preview: String, hidden: Int) {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                             options: [.bySentences, .localized]) { sub, _, _, _ in
        if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            sentences.append(s)
        }
    }
    guard !sentences.isEmpty else { return (text, 0) }
    let take = min(limit, sentences.count)
    let preview = sentences.prefix(take).joined(separator: " ")
    return (preview, sentences.count - take)
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

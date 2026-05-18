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

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                annotationToolbar
                thumbnailRow
                Divider()
                ocrSection
                Divider()
                inputModeBar
            }
            .frame(width: kDialogWidth)
            Divider()
            skillsSidebar
        }
        .frame(width: kDialogWidth + 1 + kSkillsWidth, height: kDialogHeight)
        .onAppear { vm.onAppear() }
    }

    private var inputModeBar: some View {
        HStack(spacing: 8) {
            if vm.isSending {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            } else if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $vm.inputMode) {
                ForEach(Skill.InputMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Skills sidebar

    private var skillsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text("Select a skill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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

    // MARK: - Unified title/annotation toolbar
    //
    // Lives in the title-bar zone (fullSizeContentView + titlebarAppearsTransparent).
    // The 76pt left padding clears the traffic-light buttons that macOS draws on top.

    private var annotationToolbar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 64)   // reserve room for traffic lights
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(titleText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ToolbarButton(icon: "camera.viewfinder", label: "New capture",
                          isActive: false) { triggerNewCapture() }
            ToolbarButton(icon: "rectangle.dashed", label: "Select region",
                          isActive: vm.activeTool == .rectangle) {
                vm.activeTool = vm.activeTool == .rectangle ? .none : .rectangle
            }
            ToolbarButton(icon: "pencil.tip", label: "Draw",
                          isActive: vm.activeTool == .freedraw) {
                vm.activeTool = vm.activeTool == .freedraw ? .none : .freedraw
            }
            if !vm.annotations.isEmpty || vm.croppedImage != nil {
                ToolbarButton(icon: "arrow.uturn.backward", label: "Undo",
                              isActive: false) { vm.undo() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleText: String {
        switch (vm.capture.appName, vm.capture.windowTitle) {
        case let (app?, title?): return "Clicktion — \(app) — \(title)"
        case let (app?, nil):    return "Clicktion — \(app)"
        case let (nil, title?):  return "Clicktion — \(title)"
        default:                 return "Clicktion"
        }
    }

    private func triggerNewCapture() {
        guard !vm.isSending else { return }
        Task { await CaptureManager.shared.startCapture() }
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

import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    let skill: Skill?
    var textWidth: CGFloat = 400
    var onRunCommand: ((String) -> Void)? = nil

    var body: some View {
        if message.role == .user {
            // Right-aligned: Spacer pushes bubble to the right.
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 60)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else {
            // GeometryReader in ChatView gives this view a concrete proposed width.
            // A plain VStack with trailing padding fills that width cleanly —
            // no HStack/Spacer competition that would collapse content to minimum width.
            VStack(alignment: .leading, spacing: 8) {
                assistantContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.trailing, 60)
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        // Thinking phase: show the reasoning stream as it arrives
        if !message.thinking.isEmpty {
            ThinkingStreamView(text: message.thinking, isStreaming: message.isStreaming && message.content.isEmpty)
        }

        let body = message.content.trimmingCharacters(in: .newlines)

        if message.isStreaming && body.isEmpty && message.thinking.isEmpty {
            // No content yet and no thinking either — pure wait
            HStack(spacing: 8) {
                ThinkingDotsView()
                Text("Thinking…").font(.callout.italic()).foregroundStyle(.secondary)
            }
        } else if !body.isEmpty {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    markdownText(t.trimmingCharacters(in: .newlines))
                case .code(let lang, let code):
                    codeBlock(language: lang, body: code)
                }
            }
            if message.segments.isEmpty {
                markdownText(body)
            }
        }

        if !message.isStreaming, let elapsed = message.elapsedSeconds {
            let speed = elapsed > 0 ? Double(message.tokenCount) / elapsed : 0
            Text(
                "\(message.tokenCount) tokens · "
                + String(format: "%.1fs", elapsed)
                + (speed > 0 ? " · \(Int(speed.rounded())) tok/s" : "")
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Markdown: bold, italic, inline code, bullets.
    @ViewBuilder
    private func markdownText(_ raw: String) -> some View {
        // Normalise Obsidian-style *   bullets → standard -   bullets so
        // AttributedString.full can parse them.
        let normalised = raw
            .replacingOccurrences(of: #"^\*   "#, with: "- ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\*   "#, with: "\n- ", options: .regularExpression)
        if let attr = try? AttributedString(
            markdown: normalised,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(raw)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let lang = language {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyCodeButton(text: body.trimmingCharacters(in: .newlines))
            }
            .padding(.horizontal, 10).padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(body.trimmingCharacters(in: .newlines))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if canRunCommand(body) {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        onRunCommand?(body.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Label("Run", systemImage: "play.fill").font(.caption.bold())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func canRunCommand(_ body: String) -> Bool {
        guard let skill, skill.security.allowCLI, message.role == .assistant else { return false }
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Collapsible thinking stream

struct ThinkingStreamView: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if isStreaming { ThinkingDotsView() }
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thinking dots

struct ThinkingDotsView: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7)
                    .foregroundStyle(Color.accentColor.opacity(i == phase ? 0.9 : 0.25))
                    .scaleEffect(i == phase ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Copy code button

private struct CopyCodeButton: View {
    let text: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied" : "Copy")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy to clipboard")
    }
}

struct StreamingDotsView: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().frame(width: 5, height: 5)
                    .foregroundStyle(Color.secondary.opacity(i == phase ? 0.8 : 0.2))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                phase = (phase + 1) % 3
            }
        }
    }
}

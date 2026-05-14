import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    let skill: Skill?
    var onRunCommand: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
                if message.isStreaming && message.content.isEmpty {
                    StreamingDotsView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatMessage.Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(message.role == .user ? .white : .primary)

        case .code(let language, let body):
            codeBlock(language: language, body: body)
        }
    }

    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language {
                Text(lang)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

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
                        Label("Run", systemImage: "play.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func canRunCommand(_ body: String) -> Bool {
        guard let skill, skill.security.allowCLI else { return false }
        guard message.role == .assistant else { return false }
        // Only show Run for single-line or clearly shell-like content
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:      return Color.accentColor
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        }
    }
}

// Animated streaming indicator
struct StreamingDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(Color.secondary.opacity(i == phase ? 1 : 0.3))
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

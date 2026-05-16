import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    let skill: Skill?
    var onRunCommand: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                bubbleContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Assistant bubbles fill available width so text wraps correctly
            .frame(maxWidth: message.role == .assistant ? .infinity : nil,
                   alignment: .leading)

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    // MARK: - Bubble phases

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .assistant {
            if message.isStreaming && message.content.isEmpty {
                // Phase 1 — thinking (no tokens yet)
                thinkingView
            } else {
                // Phase 2 (streaming) or 3 (done) — show content
                contentSegments
                if message.isStreaming {
                    StreamingDotsView()
                } else {
                    timingFooter
                }
            }
        } else {
            // User bubble — plain text only
            Text(message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Thinking animation

    private var thinkingView: some View {
        HStack(spacing: 8) {
            ThinkingDotsView()
            Text("Thinking…")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Content segments

    @ViewBuilder
    private var contentSegments: some View {
        ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
            segmentView(segment)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatMessage.Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(message.role == .user ? .white : .primary)

        case .code(let language, let body):
            codeBlock(language: language, body: body)
        }
    }

    // MARK: - Timing footer

    @ViewBuilder
    private var timingFooter: some View {
        if let elapsed = message.elapsedSeconds {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                let toks = message.tokenCount
                let speed = elapsed > 0 ? Double(toks) / elapsed : 0
                Text(
                    "\(toks) token\(toks == 1 ? "" : "s") · "
                    + String(format: "%.1fs", elapsed)
                    + (speed > 0 ? " · \(Int(speed.rounded())) tok/s" : "")
                )
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        }
    }

    // MARK: - Code block

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
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:      return Color.accentColor
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        }
    }
}

// MARK: - Thinking animation (pulsing dots before first token)

struct ThinkingDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(Color.accentColor.opacity(i == phase ? 0.9 : 0.25))
                    .scaleEffect(i == phase ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Streaming dots (shown while tokens arrive)

struct StreamingDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(Color.secondary.opacity(i == phase ? 0.8 : 0.2))
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

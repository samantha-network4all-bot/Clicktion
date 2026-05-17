import AppKit
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var commandOutput: String? = nil
    @Published var pendingCommand: String? = nil
    @Published var showCommandWarning: Bool = false

    let capture: CaptureResult
    let jobID: String?
    let skill: Skill?

    init(capture: CaptureResult, jobID: String?, skill: Skill?) {
        self.capture = capture
        self.jobID = jobID
        self.skill = skill
    }

    func onAppear() {
        guard let jobID else {
            messages.append(ChatMessage(
                id: UUID(),
                role: .assistant,
                content: "Service not connected. Configure a model in the menu to start."
            ))
            return
        }
        beginStream(jobID: jobID)
    }

    // MARK: - Send follow-up

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""

        messages.append(.user(text))

        guard let jobID else { return }

        Task {
            do {
                try await ServiceClient.shared.sendMessage(jobID: jobID, message: text)
                beginStream(jobID: jobID)
            } catch {
                appendError(error)
            }
        }
    }

    // MARK: - Streaming

    private func beginStream(jobID: String) {
        guard !isStreaming else { return }
        isStreaming = true

        let idx = messages.count
        messages.append(.assistantStreaming())

        Task {
            var tokenCount = 0
            do {
                try await ServiceClient.shared.streamJob(id: jobID) { [weak self] token in
                    guard let self, messages.indices.contains(idx) else { return }
                    if token.hasPrefix("\u{01}") {
                        messages[idx].thinking += String(token.dropFirst())
                    } else {
                        messages[idx].content += token
                        tokenCount += 1
                    }
                }
                if messages.indices.contains(idx) {
                    messages[idx].tokenCount = tokenCount
                    messages[idx].isStreaming = false
                    messages[idx].streamEnd = Date()
                }
            } catch {
                if messages.indices.contains(idx) {
                    messages[idx].content = "Error: \(error.localizedDescription)"
                    messages[idx].isStreaming = false
                    messages[idx].streamEnd = Date()
                }
            }
            isStreaming = false
        }
    }

    // MARK: - CLI execution

    func requestRunCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill, skill.security.allowCLI else { return }

        let isDestructive = skill.security.blocklist.contains { trimmed.contains($0) }

        if isDestructive || !skill.security.skipConfirmation {
            pendingCommand = trimmed
            showCommandWarning = isDestructive
        } else {
            executeCommand(trimmed)
        }
    }

    func confirmRunCommand() {
        guard let cmd = pendingCommand else { return }
        pendingCommand = nil
        showCommandWarning = false
        executeCommand(cmd)
    }

    func cancelRunCommand() {
        pendingCommand = nil
        showCommandWarning = false
    }

    private func executeCommand(_ command: String) {
        messages.append(.user("$ \(command)"))
        let outputIdx = messages.count
        messages.append(ChatMessage(id: UUID(), role: .assistant, content: "", isStreaming: true))

        Task.detached(priority: .userInitiated) {
            let output = await Self.runShellCommand(command)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.messages.indices.contains(outputIdx) {
                    self.messages[outputIdx].content = "```\n\(output)\n```"
                    self.messages[outputIdx].isStreaming = false
                }
            }
        }
    }

    private static func runShellCommand(_ command: String) async -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Failed to run: \(error.localizedDescription)"
        }

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? "(no output)" : combined
    }

    // MARK: - Helpers

    private func appendError(_ error: Error) {
        messages.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "Error: \(error.localizedDescription)"
        ))
    }
}

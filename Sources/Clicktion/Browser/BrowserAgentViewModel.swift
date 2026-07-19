import AppKit
import Foundation

struct AgentLogEntry: Identifiable {
    enum Role { case user, assistant, action, error }
    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class BrowserAgentViewModel: ObservableObject {
    let web = WebViewController()

    @Published var log: [AgentLogEntry] = []
    @Published var isRunning = false
    @Published var isListening = false
    @Published var urlText = ""
    /// Confirm before every click/type (not just sensitive ones).
    @Published var confirmEachAction = false
    /// Configured models, for the vision-model picker.
    @Published var models: [ModelConfig] = []

    private var conversation: [AgentMessage] = [
        AgentMessage(role: "system", content: BrowserAgentViewModel.systemPrompt)
    ]
    private var task: Task<Void, Never>?
    private let maxSteps = 8

    // MARK: - Instructions

    /// Handles a spoken/typed instruction: runs the agent loop.
    func submit(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        log.append(AgentLogEntry(role: .user, text: text))
        conversation.append(AgentMessage(role: "user", content: text))
        isRunning = true
        task = Task { [weak self] in
            await self?.runLoop()
            self?.isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        log.append(AgentLogEntry(role: .action, text: "Stopped."))
    }

    func loadModels() {
        Task { [weak self] in
            let list = (try? await ServiceClient.shared.fetchModels()) ?? []
            self?.models = list
        }
    }

    /// Directly open a URL (from the URL bar).
    func openURL() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        web.navigate(to: url)
    }

    // MARK: - Agent loop

    private func runLoop() async {
        for _ in 0..<maxSteps {
            if Task.isCancelled { return }

            let turn: AgentTurn
            do {
                turn = try await ServiceClient.shared.agentTurn(messages: conversation, tools: Self.tools)
            } catch {
                log.append(AgentLogEntry(role: .error, text: error.localizedDescription))
                return
            }

            conversation.append(AgentMessage(
                role: "assistant",
                content: turn.content.isEmpty ? nil : turn.content,
                toolCalls: turn.toolCalls.isEmpty ? nil : turn.toolCalls))

            if !turn.content.isEmpty {
                log.append(AgentLogEntry(role: .assistant, text: turn.content))
            }
            if turn.toolCalls.isEmpty { return }   // model responded with text only

            for call in turn.toolCalls {
                if Task.isCancelled { return }
                let (result, done) = await execute(call)
                conversation.append(AgentMessage(
                    role: "tool", content: result,
                    toolCallID: call.id, name: call.function.name))
                if done { return }
            }
        }
        log.append(AgentLogEntry(role: .action, text: "Reached step limit."))
    }

    private func execute(_ call: ToolCall) async -> (result: String, done: Bool) {
        let args = call.function.parsedArguments()
        switch call.function.name {
        case "navigate":
            let url = (args["url"] as? String) ?? ""
            log.append(AgentLogEntry(role: .action, text: "navigate → \(url)"))
            web.navigate(to: url)
            await web.waitUntilIdle()
            return (await pageState(prefix: "Navigated to \(web.currentURL)"), false)

        case "read_page":
            return (await pageState(prefix: "Current page: \(web.currentURL)"), false)

        case "type":
            let ref = (args["ref"] as? String) ?? ""
            let text = (args["text"] as? String) ?? ""
            if needsConfirmation(label: ref), !confirm("Allow typing into “\(ref)”?") {
                log.append(AgentLogEntry(role: .action, text: "type cancelled → \(ref)"))
                return ("Cancelled by user.", false)
            }
            log.append(AgentLogEntry(role: .action, text: "type \"\(text)\" → \(ref)"))
            let ok = await web.fill(ref: ref, text: text)
            return (ok ? "Typed into \(ref)." : "Element \(ref) not found.", false)

        case "click":
            let ref = (args["ref"] as? String) ?? ""
            let label = (args["label"] as? String) ?? ref
            if needsConfirmation(label: label), !confirm("Allow clicking “\(label)”?") {
                log.append(AgentLogEntry(role: .action, text: "click cancelled → \(label)"))
                return ("Cancelled by user.", false)
            }
            log.append(AgentLogEntry(role: .action, text: "click → \(label)"))
            let ok = await web.click(ref: ref)
            await web.waitUntilIdle()
            return (ok ? await pageState(prefix: "Clicked \(label).") : "Element \(ref) not found.", false)

        case "look_at_screen":
            let question = (args["question"] as? String)
                ?? "Describe the page and where the key interactive elements are."
            log.append(AgentLogEntry(role: .action, text: "look_at_screen: \(question)"))
            guard let image = await web.snapshot() else {
                return ("Screenshot failed.", false)
            }
            let modelID = AppState.shared.browserVisionModelID
            do {
                let description = try await ServiceClient.shared.agentVision(
                    image: image, question: question,
                    modelID: modelID.isEmpty ? nil : modelID)
                return ("Screen description: \(description)", false)
            } catch {
                return ("Vision lookup failed: \(error.localizedDescription)", false)
            }

        case "done":
            let summary = (args["summary"] as? String) ?? "Done."
            log.append(AgentLogEntry(role: .action, text: "✓ \(summary)"))
            return ("done", true)

        default:
            return ("Unknown tool \(call.function.name).", false)
        }
    }

    private func pageState(prefix: String) async -> String {
        let elements = await web.interactables()
        let text = await web.pageText()
        return """
            \(prefix)
            Interactable elements (JSON array of {ref,tag,type,label}):
            \(elements)
            Page text excerpt:
            \(text)
            """
    }

    private func needsConfirmation(label: String) -> Bool {
        confirmEachAction || isSensitive(label)
    }

    private func isSensitive(_ label: String) -> Bool {
        let l = label.lowercased()
        let keywords = ["submit", "pay", "buy", "order", "confirm", "delete",
                        "send", "login", "log in", "sign in", "checkout", "purchase"]
        return keywords.contains { l.contains($0) }
    }

    private func confirm(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Confirm action"
        alert.informativeText = question
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Tools & prompt

    private static let systemPrompt = """
        You control a web browser through tools. To act on the page you MUST use \
        the element refs returned by navigate/read_page (never invent a ref). \
        Workflow: navigate to a site, read_page to see interactable elements, \
        then type into fields and click buttons by ref. Call read_page again after \
        actions that change the page. If the element list is not enough to locate \
        something (e.g. an image or canvas UI), call look_at_screen to get a visual \
        description. Keep going until the user's request is done, then call done \
        with a short summary. Be concise.
        """

    static let tools: [AgentTool] = [
        AgentTool(name: "navigate", description: "Open a URL in the browser.",
                  parameters: [
                    "type": "object",
                    "properties": ["url": ["type": "string", "description": "The URL or domain to open."]],
                    "required": ["url"],
                  ]),
        AgentTool(name: "read_page", description: "Return the current page's interactable elements and text.",
                  parameters: ["type": "object", "properties": [String: Any]()]),
        AgentTool(name: "type", description: "Type text into a field by its ref.",
                  parameters: [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from read_page."],
                        "text": ["type": "string", "description": "Text to enter."],
                    ],
                    "required": ["ref", "text"],
                  ]),
        AgentTool(name: "click", description: "Click an element by its ref.",
                  parameters: [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from read_page."],
                        "label": ["type": "string", "description": "Human-readable label of the element."],
                    ],
                    "required": ["ref"],
                  ]),
        AgentTool(name: "look_at_screen",
                  description: "Take a screenshot and get a visual description from a vision model. Use when the element list is insufficient.",
                  parameters: [
                    "type": "object",
                    "properties": ["question": ["type": "string", "description": "What to look for or describe."]],
                  ]),
        AgentTool(name: "done", description: "Signal the task is complete.",
                  parameters: [
                    "type": "object",
                    "properties": ["summary": ["type": "string", "description": "Short summary of what was done."]],
                  ]),
    ]
}

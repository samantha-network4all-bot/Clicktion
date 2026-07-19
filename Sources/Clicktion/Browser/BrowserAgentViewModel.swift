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

    /// Number of instructions waiting to run after the current one.
    var pendingCount: Int { pending.count }

    private var conversation: [AgentMessage] = [
        AgentMessage(role: "system", content: BrowserAgentViewModel.systemPrompt)
    ]
    private var task: Task<Void, Never>?
    private var pending: [String] = []
    private let maxSteps = 12

    init() {
        loadModels()
    }

    // MARK: - Instructions

    /// Queues a spoken/typed instruction. You can keep talking while the agent
    /// is still working — new instructions run after the current one, so the
    /// model never blocks the microphone.
    func submit(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        log.append(AgentLogEntry(role: .user, text: text))
        pending.append(text)
        if !isRunning { drainQueue() }
    }

    private func drainQueue() {
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty, !Task.isCancelled {
                let next = self.pending.removeFirst()
                self.conversation.append(AgentMessage(role: "user", content: next))
                await self.runLoop()
            }
            self.isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pending.removeAll()
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
                let agentModel = AppState.shared.browserAgentModelID
                turn = try await ServiceClient.shared.agentTurn(
                    messages: conversation, tools: Self.tools,
                    modelID: agentModel.isEmpty ? nil : agentModel)
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
            let lower = url.lowercased()
            if lower.contains("://"), !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
                return ("Only http(s) URLs are supported. For visual details use look_at_screen.", false)
            }
            if lower.hasPrefix("view-source:") || lower.hasPrefix("javascript:") || lower.hasPrefix("file:") {
                return ("Only http(s) URLs are supported. For visual details use look_at_screen.", false)
            }
            log.append(AgentLogEntry(role: .action, text: "navigate → \(url)"))
            web.navigate(to: url)
            await web.waitUntilIdle()
            return (await pageState(prefix: "Navigated to \(web.currentURL)"), false)

        case "read_page":
            return (await pageState(prefix: "Current page: \(web.currentURL)"), false)

        case "type":
            let ref = (args["ref"] as? String) ?? ""
            let text = (args["text"] as? String) ?? ""
            let submit = (args["submit"] as? Bool) ?? false
            if needsConfirmation(label: ref), !confirm("Allow typing into “\(ref)”?\(submit ? " and submitting" : "")") {
                log.append(AgentLogEntry(role: .action, text: "type cancelled → \(ref)"))
                return ("Cancelled by user.", false)
            }
            log.append(AgentLogEntry(role: .action, text: "type \"\(text)\" → \(ref)\(submit ? " ⏎" : "")"))
            let ok = await web.fill(ref: ref, text: text, submit: submit)
            guard ok else { return ("Element \(ref) not found.", false) }
            if submit {
                await web.waitUntilIdle()
                return (await pageState(prefix: "Typed into \(ref) and submitted."), false)
            }
            return ("Typed into \(ref).", false)

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
            do {
                let description = try await ServiceClient.shared.agentVision(
                    image: image, question: question,
                    modelID: effectiveVisionModelID())
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

    /// The vision model to use: the explicit picker choice, otherwise the first
    /// vision-capable configured model (preferring local), otherwise nil (server
    /// falls back to the local default).
    private func effectiveVisionModelID() -> String? {
        let picked = AppState.shared.browserVisionModelID
        if !picked.isEmpty { return picked }
        let auto = models.first { $0.effectivelyLocal && $0.supportsVision }
            ?? models.first { $0.supportsVision }
        return auto?.id.uuidString
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
        You control a web browser through tools to carry out the user's request.

        Rules:
        - Act only via element refs from the MOST RECENT navigate/read_page result. \
        Refs are re-assigned every time the page is read, so never reuse a ref from \
        an earlier step; call read_page again if you are unsure of the current refs.
        - Typical flow: navigate → read_page → type into fields → click buttons or \
        links. After any action that changes the page, call read_page before acting again.
        - When you click, include a short human-readable "label" so the step is clear.
        - To run a search or submit a form, prefer type with submit=true (this \
        presses Enter and works even when there is no visible submit button); \
        otherwise click the button or matching link.
        - Only navigate to http(s) URLs. Never use view-source:, javascript:, or \
        other schemes, and don't navigate to a page you just read.
        - If a detail is only visual (e.g. a star rating shown as icons or images) \
        and not present in the page text, call look_at_screen ONCE to read it — do \
        not repeatedly read_page or navigate hoping it appears.
        - Stop as soon as the user's request is satisfied: call done with a concise \
        summary of the findings. Do not keep clicking once the goal is reached, and \
        never repeat an action that already succeeded.
        - Keep responses concise.
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
        AgentTool(name: "type", description: "Type text into a field by its ref. Set submit=true to press Enter / submit the form afterwards (e.g. to run a search).",
                  parameters: [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "Element ref from read_page."],
                        "text": ["type": "string", "description": "Text to enter."],
                        "submit": ["type": "boolean", "description": "Press Enter / submit after typing. Default false."],
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

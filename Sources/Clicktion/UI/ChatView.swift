import SwiftUI

struct ChatView: View {
    @StateObject var vm: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(minWidth: 540, minHeight: 440)
        .onAppear { vm.onAppear() }
        .alert("Run this command?", isPresented: $vm.showCommandWarning) {
            Button("Cancel", role: .cancel) { vm.cancelRunCommand() }
            Button("Run", role: .destructive) { vm.confirmRunCommand() }
        } message: {
            Text("This command may be destructive. Review it carefully before running.")
        }
        .sheet(item: confirmationBinding) { cmd in
            CommandConfirmationView(command: cmd.value) {
                vm.confirmRunCommand()
            } onCancel: {
                vm.cancelRunCommand()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: vm.capture.image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let icon = vm.skill?.icon {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                    }
                    Text(vm.skill?.name ?? "Chat")
                        .font(.headline)
                }
                if let app = vm.capture.appName {
                    HStack(spacing: 4) {
                        Text(app)
                        if let title = vm.capture.windowTitle {
                            Text("—").foregroundStyle(.tertiary)
                            Text(title).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Label(
                vm.capture.isPrivate ? "Private" : "Public",
                systemImage: vm.capture.isPrivate ? "lock.fill" : "globe"
            )
            .font(.caption)
            .foregroundStyle(vm.capture.isPrivate ? .green : .orange)
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { message in
                        MessageBubbleView(
                            message: message,
                            skill: vm.skill
                        ) { command in
                            vm.requestRunCommand(command)
                        }
                        .id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            // Also scroll when the last message content grows during streaming
            .onChange(of: vm.messages.last?.content) { _, _ in
                if let last = vm.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Follow-up message…", text: $vm.inputText)
                .textFieldStyle(.plain)
                .onSubmit { vm.sendMessage() }
                .disabled(vm.isStreaming)

            Button {
                vm.sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(vm.inputText.isEmpty || vm.isStreaming
                                     ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.isStreaming)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Pending command confirmation (non-destructive)

    private var confirmationBinding: Binding<WrappedString?> {
        Binding(
            get: {
                guard let cmd = vm.pendingCommand, !vm.showCommandWarning else { return nil }
                return WrappedString(value: cmd)
            },
            set: { _ in vm.cancelRunCommand() }
        )
    }
}

// Needed for .sheet(item:) with a String
private struct WrappedString: Identifiable {
    let id = UUID()
    let value: String
}

// Shown for non-destructive commands that still require confirmation
struct CommandConfirmationView: View {
    let command: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run this command?")
                .font(.headline)

            ScrollView(.horizontal) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Run") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

import SwiftUI

struct MenuView: View {
    @StateObject private var state = AppState.shared
    @State private var showingSkillEditor = false
    @State private var showingArchive = false
    @State private var showingModelManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            modelRow
            Divider()
            captureButton
            if state.openTodoCount > 0 {
                Divider()
                todoSection
            }
            Divider()
            menuActions
        }
        .frame(width: 300)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            Text("Clicktion")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var modelRow: some View {
        Button {
            NSWorkspace.shared.open(AppState.shared.serviceURL.appendingPathComponent("/admin/models"))
        } label: {
            HStack {
                ModelStatusIndicator()
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .help("Manage models")
    }

    private var captureButton: some View {
        Button(action: startCapture) {
            Label("Capture Screen", systemImage: "viewfinder")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Todos (\(state.openTodoCount))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            // Todo items will be populated from the service
        }
    }

    private var menuActions: some View {
        VStack(spacing: 0) {
            MenuAction(label: "Edit Skills…", icon: "square.and.pencil") {
                SkillEditorWindow.shared.show()
            }
            MenuAction(label: "Manage Models…", icon: "cpu") {
                NSWorkspace.shared.open(AppState.shared.serviceURL.appendingPathComponent("/admin/models"))
            }
            MenuAction(label: "Archive…", icon: "tray.full") {
                openArchive()
            }
            Divider().padding(.vertical, 4)
            MenuAction(label: "Settings…", icon: "gearshape") {
                SettingsWindow.shared.show()
            }
            MenuAction(label: "Quit Clicktion", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func startCapture() {
        Task { await CaptureManager.shared.startCapture() }
    }

    private func openArchive() {
        let url = AppState.shared.serviceURL.appendingPathComponent("/archive")
        NSWorkspace.shared.open(url)
    }
}

struct MenuAction: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

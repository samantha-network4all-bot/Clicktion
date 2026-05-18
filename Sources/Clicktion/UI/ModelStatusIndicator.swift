import SwiftUI

struct ModelStatusIndicator: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(displayText)
    }

    private var displayText: String {
        guard let m = state.activeModel else { return "No model" }
        if m.modelName.isEmpty || m.name.caseInsensitiveCompare(m.modelName) == .orderedSame {
            return m.name
        }
        return "\(m.name) / \(m.modelName)"
    }

    private var statusColor: Color {
        guard state.isServiceReady else { return .gray }
        return state.activeModel != nil ? .green : .orange
    }
}

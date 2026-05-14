import SwiftUI

struct ModelStatusIndicator: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(state.activeModel?.name ?? "No model")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        guard state.isServiceReady else { return .gray }
        return state.activeModel != nil ? .green : .orange
    }
}

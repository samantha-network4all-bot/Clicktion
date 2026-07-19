import SwiftUI

struct ListeningIndicatorView: View {
    let state: SpeechState
    @State private var animating = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)

            switch state {
            case .downloadingModel(let progress):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading Parakeet…")
                        .font(.callout)
                        .foregroundStyle(.white)
                    ProgressView(value: max(progress, 0.01))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 100)
                }
            case .listening:
                waveform
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.white)
            case .transcribing:
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing…")
                    .font(.callout)
                    .foregroundStyle(.white)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Solid dark HUD background so the white waveform/text stays legible on
        // any window colour (light-on-light was invisible on white apps).
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 8)
    }

    private var icon: String {
        switch state {
        case .downloadingModel: "arrow.down.circle"
        case .listening: "mic.fill"
        case .transcribing: "waveform"
        default: "mic"
        }
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: animating ? 6 + CGFloat((i % 2) * 12) : 18 - CGFloat((i % 2) * 12))
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.12),
                        value: animating
                    )
            }
        }
        .frame(height: 20)
        .onAppear { animating = true }
    }
}

import SwiftUI

struct FeatureRequestView: View {
    /// Closes the owning window (provided by FeatureRequestWindow).
    let onClose: () -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var feedback: Feedback?

    private enum Feedback {
        case saved(Int)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe the feature you'd like to see in Clicktion.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Dark mode support", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }

            HStack {
                if let feedback {
                    feedbackView(feedback)
                }
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(action: save) {
                    if isSaving {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Text("Save Request")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func feedbackView(_ fb: Feedback) -> some View {
        Group {
            switch fb {
            case .saved(let n):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved as feature-reg-\(String(format: "%04d", n)).md")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .error(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let d = description.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        isSaving = true

        Task {
            do {
                let number = try await FeatureRequestStorage.shared.save(title: t, description: d)
                await MainActor.run {
                    feedback = .saved(number)
                    isSaving = false
                    title = ""
                    description = ""
                }
            } catch {
                await MainActor.run {
                    feedback = .error(error.localizedDescription)
                    isSaving = false
                }
            }
        }
    }

}

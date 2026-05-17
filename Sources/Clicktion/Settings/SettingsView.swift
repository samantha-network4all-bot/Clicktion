import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("General").tag(0)
                Text("Privacy").tag(1)
                Text("Profiles").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if selectedTab == 0 {
                GeneralTab()
            } else if selectedTab == 1 {
                PrivacyTab()
            } else {
                ProfilesTab()
            }
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @StateObject private var state = AppState.shared
    @State private var models: [ModelConfig] = []
    @State private var defaultModelID: UUID? = nil
    @State private var search = ""

    private static let allLanguages: [(code: String, name: String)] = {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier).compactMap { code -> (String, String)? in
            guard let name = Locale(identifier: "en").localizedString(forLanguageCode: code),
                  name != code, !name.isEmpty else { return nil }
            return (code, name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private static let systemLanguageName: String = {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }()

    private var filtered: [(code: String, name: String)] {
        guard !search.isEmpty else { return Self.allLanguages }
        return Self.allLanguages.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !models.isEmpty {
                modelRow
                Divider()
            }
            diskRow
            Divider()
            languageSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if let loaded = try? await ServiceClient.shared.fetchModels() {
                models = loaded
                defaultModelID = loaded.first(where: { $0.isDefault })?.id
            }
        }
    }

    private var diskRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture disk usage").font(.subheadline).fontWeight(.medium)
                Text("Oldest screenshots are deleted automatically above this limit. Captures with OCR text keep their chat history (image only removed).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Stepper(value: $state.maxDiskUsageMB, in: 50...10_000, step: 50) {
                Text("\(state.maxDiskUsageMB) MB")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .frame(width: 200)
        }
    }

    private var modelRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default model").font(.subheadline).fontWeight(.medium)
                Text("Used for all captures unless overridden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $defaultModelID) {
                ForEach(models) { m in
                    Text(m.name).tag(Optional(m.id))
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .onChange(of: defaultModelID) { _, newID in
                guard let id = newID else { return }
                Task {
                    if let updated = try? await ServiceClient.shared.setDefaultModel(id: id) {
                        models = updated
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Response language").font(.subheadline).fontWeight(.medium)
                Text("The AI will always reply in the selected language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            systemLangButton
            TextField("Search languages…", text: $search).textFieldStyle(.roundedBorder)
            langList
        }
    }

    private var systemLangButton: some View {
        let sel = state.responseLanguage == "system"
        return Button { state.responseLanguage = "system" } label: {
            HStack {
                Text("System default (\(Self.systemLanguageName))").font(.callout)
                Spacer()
                if sel { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(sel ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(sel ? Color.accentColor.opacity(0.4) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var langList: some View {
        ScrollViewReader { proxy in
            List(filtered, id: \.code) { lang in
                langRow(lang).id(lang.code)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }
            .listStyle(.plain)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            .onAppear {
                let target = state.responseLanguage == "system" ? Self.systemLanguageName : state.responseLanguage
                if let code = Self.allLanguages.first(where: { $0.name == target })?.code {
                    proxy.scrollTo(code, anchor: .center)
                }
            }
        }
    }

    private func langRow(_ lang: (code: String, name: String)) -> some View {
        let sel = state.responseLanguage == lang.name
        return Button { state.responseLanguage = lang.name } label: {
            HStack {
                Text(lang.name).font(.callout).foregroundStyle(sel ? Color.accentColor : Color.primary)
                Spacer()
                if sel { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.callout.weight(.semibold)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Privacy behaviour").font(.subheadline).fontWeight(.medium)
                Text("Controls how your captures are handled across all sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            privacyOption(
                mode: .privateOnly,
                icon: "lock.fill",
                title: "Private only — local LLMs",
                description: "Every capture stays on your network. Only LLMs running on localhost or your local network are used. The privacy toggle is hidden in the capture screen."
            )
            privacyOption(
                mode: .publicEnabled,
                icon: "globe",
                title: "Trust my LLM provider",
                description: "Captures can be sent to any configured LLM, including remote providers. A privacy toggle appears on each capture so you can decide per capture."
            )
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func privacyOption(mode: AppState.PrivacyMode, icon: String,
                               title: String, description: String) -> some View {
        let selected = state.privacyMode == mode
        return Button { state.privacyMode = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.callout)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        Text(title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    Text(description)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                selected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profiles

private struct ProfilesTab: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileCardView(title: "Thinking",
                                subtitle: "Model reasons before answering. Best for complex analysis.",
                                icon: "brain",
                                profile: $state.thinkingProfile,
                                isThinking: true)
                ProfileCardView(title: "Direct",
                                subtitle: "Fast, concise answers. No reasoning steps shown.",
                                icon: "bolt",
                                profile: $state.nonThinkingProfile,
                                isThinking: false)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileCardView: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var profile: AppState.ModelProfile
    let isThinking: Bool

    private var tempSlider: Binding<Double> {
        Binding(
            get: { max(0, profile.temperature) },
            set: { profile.temperature = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Master system prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $profile.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: tempSlider, in: 0...2, step: 0.05)
                        Text(profile.temperature < 0 ? "auto" : String(format: "%.2f", profile.temperature))
                            .font(.caption.monospacedDigit())
                            .frame(width: 36)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max tokens").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $profile.maxTokens) {
                        Text("Auto").tag(0)
                        Text("512").tag(512)
                        Text("1 024").tag(1024)
                        Text("2 048").tag(2048)
                        Text("4 096").tag(4096)
                        Text("8 192").tag(8192)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }

            if isThinking {
                Toggle("Enable thinking / reasoning", isOn: $profile.thinkingEnabled)
                    .font(.callout).toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Reset to defaults") {
                    profile = isThinking ? .thinkingDefault : .nonThinkingDefault
                }
                .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

import SwiftUI

struct SettingsView: View {
    @StateObject private var state = AppState.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                tabButton("General", tag: 0)
                tabButton("Privacy", tag: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 0)

            Divider().padding(.top, 8)

            if selectedTab == 0 {
                GeneralTab()
            } else {
                PrivacyTab()
            }
        }
        .frame(width: 360, height: 520)
    }

    private func tabButton(_ label: String, tag: Int) -> some View {
        let active = selectedTab == tag
        return Button { selectedTab = tag } label: {
            Text(label)
                .font(.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @StateObject private var state = AppState.shared
    @State private var search = ""
    @State private var models: [ModelConfig] = []
    @State private var defaultModelID: UUID? = nil

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Default model
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default model").font(.subheadline).fontWeight(.medium)
                            Text("Used for all captures unless overridden.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Default model", selection: $defaultModelID) {
                            ForEach(models) { model in
                                Text(model.name).tag(Optional(model.id))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: defaultModelID) { _, newID in
                            guard let id = newID else { return }
                            Task {
                                if let updated = try? await ServiceClient.shared.setDefaultModel(id: id) {
                                    models = updated
                                }
                            }
                        }
                    }
                    Divider()
                }

                // Response language
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Response language").font(.subheadline).fontWeight(.medium)
                        Text("The AI will always reply in the selected language.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    systemLanguageRow
                    TextField("Search languages…", text: $search).textFieldStyle(.roundedBorder)
                    languageList
                }
            }
            .padding(16)
        }
        .task {
            if let loaded = try? await ServiceClient.shared.fetchModels() {
                models = loaded
                defaultModelID = loaded.first(where: { $0.isDefault })?.id
            }
        }
    }

    private var systemLanguageRow: some View {
        let name = Self.systemLanguageName
        let isSelected = state.responseLanguage == "system"
        return Button { state.responseLanguage = "system" } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("System default").font(.callout)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                isSelected ? Color.accentColor.opacity(0.4) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var languageList: some View {
        ScrollViewReader { proxy in
            List(filtered, id: \.code) { lang in
                languageRow(lang).id(lang.code)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
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

    private func languageRow(_ lang: (code: String, name: String)) -> some View {
        let isSelected = state.responseLanguage != "system" && state.responseLanguage == lang.name
        return Button { state.responseLanguage = lang.name } label: {
            HStack {
                Text(lang.name).font(.callout)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Privacy tab

private struct PrivacyTab: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Privacy behaviour").font(.subheadline).fontWeight(.medium)
                    Text("Controls how your captures are handled across all sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                privacyOption(
                    mode: .privateOnly,
                    icon: "lock.fill",
                    title: "Private only — local LLMs",
                    description: "Every capture stays on your network. Only LLMs running on localhost or your local network are used. The privacy toggle is hidden in the capture screen — there is nothing to toggle."
                )

                privacyOption(
                    mode: .publicEnabled,
                    icon: "globe",
                    title: "Trust my LLM provider",
                    description: "Captures can be sent to any configured LLM, including remote providers. A privacy toggle appears on each capture so you can decide per capture what to share with your provider."
                )
            }
            .padding(16)
        }
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
                        Image(systemName: icon)
                            .font(.callout)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        Text(title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                selected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor)
            ))
        }
        .buttonStyle(.plain)
    }
}

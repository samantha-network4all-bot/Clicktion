import SwiftUI

struct SettingsView: View {
    @StateObject private var state = AppState.shared
    @State private var search = ""

    // All ISO languages with English display names, sorted alphabetically.
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
        return Self.allLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Settings")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Response Language section
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Response language")
                        .font(.subheadline).fontWeight(.medium)
                    Text("The AI will always reply in the selected language.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // System language shortcut
                systemLanguageRow

                TextField("Search languages…", text: $search)
                    .textFieldStyle(.roundedBorder)

                languageList
            }
            .padding(16)
        }
        .frame(width: 360, height: 500)
    }

    // MARK: - Subviews

    private var systemLanguageRow: some View {
        let name = Self.systemLanguageName
        let isSelected = state.responseLanguage == "system"
        return Button {
            state.responseLanguage = "system"
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("System default").font(.callout)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                isSelected ? Color.accentColor.opacity(0.4) : Color.clear
            ))
        }
        .buttonStyle(.plain)
    }

    private var languageList: some View {
        ScrollViewReader { proxy in
            List(filtered, id: \.code) { lang in
                languageRow(lang)
                    .id(lang.code)
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
        return Button {
            state.responseLanguage = lang.name
        } label: {
            HStack {
                Text(lang.name)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

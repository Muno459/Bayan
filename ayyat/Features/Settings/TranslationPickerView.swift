import SwiftUI

/// Picker for English Quran translations (Saheeh, Pickthall, Yusuf Ali, etc.).
/// Backed by `GET /content/api/v4/resources/translations`.
/// Selection persists via `SettingsManager.selectedTranslationId`.
struct TranslationPickerView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(QuranStore.self) private var quranStore

    @State private var translations: [TranslationResource] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && translations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Couldn't load translations",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            } else {
                List {
                    Section {
                        ForEach(englishTranslations) { t in
                            translationRow(t)
                        }
                    } header: {
                        Text("English (\(englishTranslations.count))")
                    } footer: {
                        Text("Saheeh International is the default. Tap any other to switch. New verses use the chosen translation.")
                    }

                    if !otherTranslations.isEmpty {
                        Section("Other languages") {
                            ForEach(otherTranslations) { t in
                                translationRow(t)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Translation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var englishTranslations: [TranslationResource] {
        translations.filter { $0.languageName.lowercased() == "english" }
            .sorted { $0.displayName < $1.displayName }
    }

    private var otherTranslations: [TranslationResource] {
        translations.filter { $0.languageName.lowercased() != "english" }
            .sorted { $0.languageName < $1.languageName }
    }

    private func translationRow(_ t: TranslationResource) -> some View {
        Button {
            settings.selectedTranslationId = t.id
            Haptics.selection()
            // Re-fetch verses for the currently-open chapter with the new
            // translation. Saheeh (131) comes from local SQLite; everything
            // else routes through the Content API.
            Task { await quranStore.reloadVerses(translationId: t.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AyyatColors.textPrimary)
                    if let author = t.authorName, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 12))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }
                Spacer()
                if settings.selectedTranslationId == t.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AyyatColors.primary)
                }
            }
            // Hit-test the full row width including the Spacer gap.
            // Without this, taps on the empty space between the label
            // and the checkmark were dead because SwiftUI's default
            // hit shape ignores Spacers.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            translations = try await quranStore.apiClient.fetchTranslations()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

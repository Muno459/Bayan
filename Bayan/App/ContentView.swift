import SwiftUI

struct ContentView: View {
    @Environment(QuranStore.self) private var quranStore
    @State private var selectedTab: AppTab = .read

    var body: some View {
        TabView(selection: $selectedTab) {
            ReadTab()
                .tabItem {
                    Label("Read", systemImage: "book.fill")
                }
                .tag(AppTab.read)

            LearnTab()
                .tabItem {
                    Label("Learn", systemImage: "graduationcap.fill")
                }
                .tag(AppTab.learn)

            ProgressTab()
                .tabItem {
                    Label("Progress", systemImage: "chart.bar.fill")
                }
                .tag(AppTab.progress)

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .tint(BayanColors.primary)
        .task {
            await quranStore.loadChapters()
        }
    }
}

enum AppTab: Hashable {
    case read, learn, progress, settings
}

// MARK: - Read Tab

struct ReadTab: View {
    var body: some View {
        NavigationStack {
            ChapterListView()
        }
    }
}

// MARK: - Learn Tab (Placeholder)

struct LearnTab: View {
    @Environment(VocabularyStore.self) private var vocabularyStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BayanSpacing.lg) {
                    // Stats Header
                    VStack(spacing: BayanSpacing.sm) {
                        Text("\(vocabularyStore.totalWordsEncountered)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(BayanColors.primary)

                        Text("Words Encountered")
                            .font(BayanFonts.body)
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BayanSpacing.xl)

                    // Mastery breakdown
                    VStack(spacing: BayanSpacing.md) {
                        MasteryRow(label: "Mastered", count: vocabularyStore.masteredCount, color: BayanColors.mastered, icon: "checkmark.seal.fill")
                        MasteryRow(label: "Familiar", count: vocabularyStore.familiarCount, color: BayanColors.introduced, icon: "star.fill")
                        MasteryRow(label: "Learning", count: vocabularyStore.learningCount, color: BayanColors.learning, icon: "flame.fill")
                    }
                    .padding(BayanSpacing.md)
                    .bayanCard()
                    .padding(.horizontal, BayanSpacing.md)

                    // Info card
                    VStack(alignment: .leading, spacing: BayanSpacing.sm) {
                        Label("How Learning Works", systemImage: "lightbulb.fill")
                            .font(BayanFonts.subtitle)
                            .foregroundStyle(BayanColors.gold)

                        Text("As you read the Quran, Bayan tracks every Arabic word you encounter. Words are gradually introduced in place of their English translations as you become more familiar with them.")
                            .font(BayanFonts.body)
                            .foregroundStyle(BayanColors.textSecondary)
                            .lineSpacing(4)
                    }
                    .padding(BayanSpacing.md)
                    .bayanCard()
                    .padding(.horizontal, BayanSpacing.md)
                }
            }
            .background(BayanColors.background)
            .navigationTitle("Learn")
        }
    }
}

private struct MasteryRow: View {
    let label: String
    let count: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: BayanSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 32)

            Text(label)
                .font(BayanFonts.bodyMedium)
                .foregroundStyle(BayanColors.textPrimary)

            Spacer()

            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.vertical, BayanSpacing.xs)
    }
}

// MARK: - Progress Tab (Placeholder)

struct ProgressTab: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: BayanSpacing.lg) {
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 64))
                    .foregroundStyle(BayanColors.primary.opacity(0.3))

                Text("Reading progress and streaks\ncoming soon")
                    .font(BayanFonts.body)
                    .foregroundStyle(BayanColors.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(BayanColors.background)
            .navigationTitle("Progress")
        }
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var s = settings

        NavigationStack {
            Form {
                Section("Arabic Text") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(settings.arabicFontSize))")
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                    Slider(value: $s.arabicFontSize, in: 20...44, step: 2)
                        .tint(BayanColors.primary)
                }

                Section("Translation") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(settings.translationFontSize))")
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                    Slider(value: $s.translationFontSize, in: 12...24, step: 1)
                        .tint(BayanColors.primary)

                    Toggle("Show Transliteration", isOn: $s.showTransliteration)
                        .tint(BayanColors.primary)
                }

                Section("Audio") {
                    Toggle("Auto-play Audio", isOn: $s.autoPlayAudio)
                        .tint(BayanColors.primary)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                    HStack {
                        Text("Data Source")
                        Spacer()
                        Text("Quran Foundation API")
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
        .environment(QuranStore())
        .environment(VocabularyStore())
        .environment(AudioPlaybackManager())
        .environment(SettingsManager())
}

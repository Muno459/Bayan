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

            ProgressTabView()
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

// MARK: - Learn Tab

struct LearnTab: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(UserStore.self) private var userStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BayanSpacing.lg) {
                    // Empty state for first launch
                    if vocabularyStore.totalWordsEncountered == 0 {
                        VStack(spacing: 12) {
                            Image(systemName: "book.and.wrench")
                                .font(.system(size: 40))
                                .foregroundStyle(BayanColors.primary.opacity(0.4))
                            Text("Start Reading to Learn")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(BayanColors.textPrimary)
                            Text("Open any surah from the Read tab. As you read, Bayan will track every Arabic word and help you learn it.")
                                .font(.system(size: 14))
                                .foregroundStyle(BayanColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.vertical, 32)
                    }

                    // Daily Word
                    DailyWordCard()
                        .padding(.horizontal, BayanSpacing.md)

                    // Continue Reading
                    if let lastSession = userStore.sessions.last {
                        ContinueReadingCard(lastSession: lastSession)
                            .padding(.horizontal, BayanSpacing.md)
                    }

                    // Quiz button
                    NavigationLink {
                        QuizView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Vocabulary Quiz", systemImage: "brain.head.profile")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(BayanColors.textPrimary)
                                Text("Test your knowledge of \(vocabularyStore.totalWordsEncountered) words")
                                    .font(.system(size: 13))
                                    .foregroundStyle(BayanColors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(BayanColors.textSecondary)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(BayanColors.primary.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(BayanColors.primary.opacity(0.12), lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, BayanSpacing.md)

                    // Mastery stats
                    VStack(spacing: BayanSpacing.md) {
                        Text("Vocabulary Breakdown")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BayanColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        MasteryRow(label: "Mastered", count: vocabularyStore.masteredCount, color: BayanColors.mastered, icon: "checkmark.seal.fill")
                        MasteryRow(label: "Familiar", count: vocabularyStore.familiarCount, color: BayanColors.introduced, icon: "star.fill")
                        MasteryRow(label: "Learning", count: vocabularyStore.learningCount, color: BayanColors.learning, icon: "flame.fill")
                        MasteryRow(label: "Total Encountered", count: vocabularyStore.totalWordsEncountered, color: BayanColors.textPrimary, icon: "book.fill")
                    }
                    .padding(BayanSpacing.md)
                    .bayanCard()
                    .padding(.horizontal, BayanSpacing.md)
                }
                .padding(.top, BayanSpacing.sm)
            }
            .background(BayanColors.background)
            .navigationTitle("Learn")
        }
    }
}

// MARK: - Continue Reading Card

private struct ContinueReadingCard: View {
    let lastSession: ReadingSession

    var body: some View {
        NavigationLink(value: lastSession.chapterId) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue Reading")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BayanColors.textSecondary)
                    Text("Surah \(lastSession.chapterId) - Verse \(lastSession.startVerseKey)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BayanColors.textPrimary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(BayanColors.primary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(BayanColors.primary.opacity(0.06))
            )
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

// MARK: - Settings Tab

struct SettingsTab: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(QuranStore.self) private var quranStore

    var body: some View {
        @Bindable var s = settings

        NavigationStack {
            Form {
                Section("Reading") {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text("\(Int(settings.translationFontSize))")
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                    Slider(value: $s.translationFontSize, in: 12...24, step: 1)
                        .tint(BayanColors.primary)
                }

                Section {
                    Toggle("Show Full English Translation", isOn: $s.showFullTranslation)
                        .tint(BayanColors.primary)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Shows the complete English translation below the progressive substitution line.")
                }

                // Reciter Picker
                Section {
                    Picker("Reciter", selection: $s.selectedReciterId) {
                        ForEach(quranStore.reciters) { reciter in
                            Text(reciter.displayName)
                                .tag(reciter.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Toggle("Auto-play Pronunciation", isOn: $s.autoPlayWordPronunciation)
                        .tint(BayanColors.primary)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Choose the reciter for chapter audio playback. Word pronunciation uses the standard Quran audio.")
                }

                // Downloads
                Section {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        HStack {
                            Label("Offline Audio", systemImage: "arrow.down.circle")
                            Spacer()
                            Text("Manage")
                                .foregroundStyle(BayanColors.textSecondary)
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Download word pronunciation audio for offline use.")
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
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
        .environment(UserStore())
        .environment(VocabularyStore())
        .environment(AudioPlaybackManager())
        .environment(SettingsManager())
}

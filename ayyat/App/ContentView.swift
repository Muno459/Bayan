import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @Environment(QuranStore.self) private var quranStore
    @State private var nav = AppNavigation()

    var body: some View {
        // `@Bindable` here is the canonical way to derive bindings from
        // an `@Observable` class held in `@State`. The TabView's
        // selection binding then reactively follows `nav.selectedTab`
        // changes triggered by `nav.openInRead(...)` — so tapping a
        // bookmark in Learn flips the bottom tab bar to Read.
        @Bindable var bindableNav = nav
        TabView(selection: $bindableNav.selectedTab) {
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
        .tint(AyyatColors.primary)
        .environment(nav)
        // Hifz used to live as its own tab gated on vocabulary count, but it
        // works much better inline in the reader (three-dot menu → Memorize
        // Mode) — that way the slider hides words across the *whole surah*
        // in context instead of a separate isolated screen.
        .task {
            await quranStore.loadChapters()
        }
    }
}

enum AppTab: Hashable {
    case read, learn, progress, settings
}

/// Coordinator for cross-tab navigation. Anywhere in the app you can
/// `@Environment(AppNavigation.self) private var nav` and:
///   nav.openInRead(chapterId: 1)
/// to switch to the Read tab and push the chapter onto its NavigationStack.
@Observable @MainActor
final class AppNavigation {
    var selectedTab: AppTab = .read
    var readPath = NavigationPath()

    /// Switch to the Read tab and push the chapter so the user lands
    /// directly in the verse reader. Replaces the current path instead
    /// of appending — that way repeated bookmark / continue-reading taps
    /// don't stack multiple readers on top of each other, which caused
    /// the back gesture to loop through stale chapters.
    func openInRead(chapterId: Int) {
        selectedTab = .read
        readPath = NavigationPath()
        readPath.append(chapterId)
    }
}


// MARK: - Read Tab

struct ReadTab: View {
    @Environment(AppNavigation.self) private var nav
    @Environment(QuranStore.self) private var quranStore

    var body: some View {
        @Bindable var bindableNav = nav
        NavigationStack(path: $bindableNav.readPath) {
            ChapterListView()
                .navigationDestination(for: Int.self) { chapterId in
                    if let chapter = quranStore.chapters.first(where: { $0.id == chapterId }) {
                        VerseReaderView(chapter: chapter)
                    }
                }
        }
    }
}

// MARK: - Learn Tab

struct LearnTab: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(UserStore.self) private var userStore
    @Environment(QuranStore.self) private var quranStore
    @Environment(OIDCAuthService.self) private var auth

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BayanSpacing.lg) {
                    // Streak + today's goal — only when signed in.
                    // Hits two QF User APIs: /v1/streaks/current-streak-days
                    // and /v1/goals/get-todays-plan.
                    if auth.isSignedIn {
                        streakAndGoalCard
                            .padding(.horizontal, BayanSpacing.md)
                    }

                    // Empty state for first launch
                    if vocabularyStore.totalWordsEncountered == 0 {
                        VStack(spacing: 12) {
                            Image(systemName: "book.and.wrench")
                                .font(.system(size: 40))
                                .foregroundStyle(AyyatColors.primary.opacity(0.4))
                            Text("Start Reading to Learn")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AyyatColors.textPrimary)
                            Text("Open any surah from the Read tab. As you read, ayyat will track every Arabic word and help you learn it.")
                                .font(.system(size: 14))
                                .foregroundStyle(AyyatColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.vertical, 32)
                    }

                    // Daily Word
                    DailyWordCard()
                        .padding(.horizontal, BayanSpacing.md)

                    // Quiz button
                    NavigationLink {
                        QuizView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Vocabulary Quiz", systemImage: "brain.head.profile")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AyyatColors.textPrimary)
                                Text("Test your knowledge of \(vocabularyStore.totalWordsEncountered) words")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AyyatColors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AyyatColors.textSecondary)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(AyyatColors.primary.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(AyyatColors.primary.opacity(0.12), lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, BayanSpacing.md)

                    // Bookmarks + Reflections rolled into one compact
                    // "Library" row with two segments — saves a card per
                    // entry while still giving one-tap access.
                    HStack(spacing: 12) {
                        NavigationLink {
                            BookmarksListView { _, _ in }
                        } label: {
                            libraryChip(
                                systemImage: "bookmark.fill",
                                title: "Bookmarks",
                                count: userStore.bookmarks.count
                            )
                        }
                        NavigationLink {
                            ReflectionsListView()
                        } label: {
                            libraryChip(
                                systemImage: "text.bubble.fill",
                                title: "Reflections",
                                count: nil
                            )
                        }
                    }
                    .padding(.horizontal, BayanSpacing.md)

                    // Mastery stats
                    VStack(spacing: BayanSpacing.md) {
                        Text("Vocabulary Breakdown")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AyyatColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        MasteryRow(label: "Mastered", count: vocabularyStore.masteredCount, color: AyyatColors.mastered, icon: "checkmark.seal.fill")
                        MasteryRow(label: "Familiar", count: vocabularyStore.familiarCount, color: AyyatColors.introduced, icon: "star.fill")
                        MasteryRow(label: "Learning", count: vocabularyStore.learningCount, color: AyyatColors.learning, icon: "flame.fill")
                        MasteryRow(label: "Total Encountered", count: vocabularyStore.totalWordsEncountered, color: AyyatColors.textPrimary, icon: "book.fill")
                    }
                    .padding(BayanSpacing.md)
                    .bayanCard()
                    .padding(.horizontal, BayanSpacing.md)
                }
                .padding(.top, BayanSpacing.sm)
            }
            .background(AyyatColors.background)
            .navigationTitle("Learn")
            // Note: chapter navigation no longer lives on this stack.
            // The Learn-tab content uses `nav.openInRead(...)` to switch
            // to the Read tab and push the chapter there — that's why
            // the back gesture from the verse reader lands on the
            // chapter list (Read tab root) instead of back here on Learn.
            // A duplicate `.navigationDestination(for: Int.self)` here
            // caused SwiftUI's "declared earlier on the stack" warning.
            .task(id: auth.isSignedIn) {
                // Pull streak + today's plan whenever the Learn tab
                // appears or sign-in state changes. Both endpoints are
                // cheap GETs; offline they return defaults.
                if auth.isSignedIn {
                    await userStore.refreshServerProgress()
                }
            }
        }
    }

    /// Streak count + today's goal progress, both fetched from QF's
    /// User APIs (Activity Days + Goals). Falls back to the local-only
    /// streak if the server endpoints are unreachable.
    @ViewBuilder
    private var streakAndGoalCard: some View {
        HStack(spacing: 12) {
            // Streak side
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("\(userStore.effectiveStreakDays)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AyyatColors.textPrimary)
                }
                Text(userStore.effectiveStreakDays == 1 ? "day streak" : "day streak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.orange.opacity(0.18), lineWidth: 1)
                    )
            )

            // Today's goal side
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .foregroundStyle(AyyatColors.primary)
                    Text(goalProgressLabel)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AyyatColors.textPrimary)
                }
                Text("today's goal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AyyatColors.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(AyyatColors.primary.opacity(0.18), lineWidth: 1)
                    )
            )
        }
    }

    private var goalProgressLabel: String {
        if let p = userStore.todaysGoalPlan?.progress {
            return "\(Int(p * 100))%"
        }
        // No goal set yet — invite the user to make one.
        return "Set"
    }

    /// Compact half-width chip used for Bookmarks/Reflections in the
    /// Learn tab. Two of these in an HStack replace what used to be
    /// two full-width cards.
    private func libraryChip(systemImage: String, title: String, count: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AyyatColors.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                // Show the count when present, or an em-space when not,
                // so the second line of text occupies the same height
                // in both chips → both cards line up. Previously the
                // Reflections chip (no count) was shorter than the
                // Bookmarks chip (has count) and they didn't match.
                Text(count.map { "\($0)" } ?? " ")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AyyatColors.primary.opacity(0.06))
        )
    }
}

// MARK: - Continue Reading Card

private struct ContinueReadingCard: View {
    let lastSession: ReadingSession
    @Environment(QuranStore.self) private var quranStore
    @Environment(AppNavigation.self) private var nav

    private var chapterName: String {
        quranStore.chapters.first(where: { $0.id == lastSession.chapterId })?.nameSimple
            ?? "Surah \(lastSession.chapterId)"
    }

    /// Just the verse number from "2:5" → "5". Avoids "Surah 2 - Verse 2:5"
    /// duplication.
    private var verseLabel: String {
        let key = lastSession.endVerseKey ?? lastSession.startVerseKey
        return key.split(separator: ":").last.map(String.init) ?? "1"
    }

    var body: some View {
        Button {
            // Cross-tab jump — Continue Reading lives on the Learn tab
            // but the destination is the Read tab's verse reader, so
            // route through the AppNavigation coordinator.
            nav.openInRead(chapterId: lastSession.chapterId)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue Reading")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AyyatColors.textSecondary)
                    Text("\(chapterName) · Verse \(verseLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AyyatColors.textPrimary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(AyyatColors.primary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AyyatColors.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .foregroundStyle(AyyatColors.textPrimary)

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
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(OIDCAuthService.self) private var auth
    @AppStorage("ayyat.dailyVerseGoal") private var dailyGoal: Int = 10
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var showSignOutConfirm = false
    @State private var showGoalSheet = false

    private var checker: PronunciationChecker {
        SharedPronunciationChecker.checker
    }

    /// Subtitle line under the user's name when signed in. Falls back to
    /// generic copy while /userinfo is still in flight.
    private var accountSubtitle: String {
        if let email = auth.userInfo?.email, !email.isEmpty {
            return email
        }
        return "Reading sessions sync to your account"
    }

    private var currentTranslationName: String {
        // Cheap label without round-tripping fetchTranslations on settings open.
        switch settings.selectedTranslationId {
        case 131: "Saheeh International"
        case 19:  "Pickthall"
        case 22:  "Yusuf Ali"
        case 20:  "Muhsin Khan"
        case 33:  "Indonesian (Lampung)"
        case 77:  "Diyanet (Turkish)"
        case 136: "Montada (French)"
        case 27:  "Bubenheim (German)"
        default:  "Translation \(settings.selectedTranslationId)"
        }
    }

    var body: some View {
        @Bindable var s = settings

        NavigationStack {
            Form {
                // Account
                Section {
                    if auth.isSignedIn {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(AyyatColors.mastered.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(AyyatColors.mastered)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(auth.userInfo?.displayName ?? "Signed in")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AyyatColors.textPrimary)
                                Text(accountSubtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AyyatColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Sign Out", role: .destructive) {
                                showSignOutConfirm = true
                            }
                                .buttonStyle(.borderless)
                                .font(.system(size: 13))
                                .confirmationDialog(
                                    "Sign out of your Quran.com account?",
                                    isPresented: $showSignOutConfirm,
                                    titleVisibility: .visible
                                ) {
                                    Button("Sign Out", role: .destructive) {
                                        auth.signOut()
                                        signInError = nil
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Bookmarks, reflections and reading-session sync will pause until you sign back in. Your local data on this device stays.")
                                }
                        }
                    } else {
                        Button {
                            signInError = nil
                            isSigningIn = true
                            Task {
                                defer { isSigningIn = false }
                                do { try await auth.signIn() }
                                catch {
                                    // Filter user-cancelled errors —
                                    // showing "The operation couldn't be
                                    // completed (com.apple.AuthenticationServices
                                    // .WebAuthenticationSession error 1.)"
                                    // makes the user think the app broke
                                    // when they themselves dismissed.
                                    if let asError = error as? ASWebAuthenticationSessionError,
                                       asError.code == .canceledLogin
                                    {
                                        return
                                    }
                                    signInError = (error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(AyyatColors.primary.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "person.crop.circle.badge.plus")
                                        .font(.system(size: 16))
                                        .foregroundStyle(AyyatColors.primary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sign in with Quran.com")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(AyyatColors.textPrimary)
                                    Text("Sync bookmarks and reading sessions")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AyyatColors.textSecondary)
                                }
                                Spacer()
                                if isSigningIn || auth.isSigningIn {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSigningIn || auth.isSigningIn)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if let signInError {
                        Text(signInError).foregroundStyle(.red)
                    }
                }

                // Voice AI
                Section {
                    NavigationLink {
                        VoiceAISettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(checker.isModelLoaded ? AyyatColors.mastered.opacity(0.15) : AyyatColors.primary.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: checker.isModelLoaded ? "checkmark.circle.fill" : "waveform")
                                    .font(.system(size: 16))
                                    .foregroundStyle(checker.isModelLoaded ? AyyatColors.mastered : AyyatColors.primary)
                                    .symbolEffect(.pulse, options: .repeating, isActive: checker.isModelLoading)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice AI")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AyyatColors.textPrimary)
                                Text(checker.loadingStatus == "Optimized" ? "Optimized" :
                                     checker.isModelLoaded ? "Ready" : "Loading...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AyyatColors.textSecondary)
                            }
                        }
                    }
                }

                Section("Reading") {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text("\(Int(settings.translationFontSize))")
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                    Slider(value: $s.translationFontSize, in: 12...24, step: 1)
                        .tint(AyyatColors.primary)
                }

                // Learning Mode
                Section {
                    @Bindable var vocab = vocabularyStore
                    Picker("Learning Mode", selection: $vocab.useTransliteration) {
                        Text("Arabic Script").tag(false)
                        Text("Transliteration").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Learning Mode")
                } footer: {
                    Text(vocabularyStore.useTransliteration
                         ? "English words become phonetic pronunciation guides."
                         : "English words become original Arabic script. Reading Arabic directly carries greater reward.")
                }

                Section {
                    Toggle("Show Full English Translation", isOn: $s.showFullTranslation)
                        .tint(AyyatColors.primary)

                    // Appearance: lifted out of the surah-reader toolbar
                    // into Settings where it's globally discoverable.
                    Picker("Appearance", selection: $s.darkModeOverride) {
                        Text("System").tag(SettingsManager.DarkModeOverride.system)
                        Text("Light").tag(SettingsManager.DarkModeOverride.light)
                        Text("Dark").tag(SettingsManager.DarkModeOverride.dark)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Display")
                }

                // Translation
                Section {
                    NavigationLink {
                        TranslationPickerView()
                    } label: {
                        HStack {
                            Label("Translation", systemImage: "text.alignleft")
                            Spacer()
                            Text(currentTranslationName)
                                .foregroundStyle(AyyatColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("Multi-language translations powered by the Quran Foundation Content API.")
                }

                // Goal
                Section {
                    Button {
                        showGoalSheet = true
                    } label: {
                        HStack {
                            Label("Daily Reading Goal", systemImage: "target")
                                .foregroundStyle(AyyatColors.textPrimary)
                            Spacer()
                            Text("\(dailyGoal) verse\(dailyGoal == 1 ? "" : "s")")
                                .foregroundStyle(AyyatColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
                        }
                        .contentShape(Rectangle())   // full-row hit target
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Goal")
                } footer: {
                    Text("Set a daily reading target. Synced to your Quran.com account.")
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
                        .tint(AyyatColors.primary)
                    Toggle("Auto Pronunciation Check", isOn: $s.autoPronunciationCheck)
                        .tint(AyyatColors.primary)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Choose the reciter for chapter audio. Auto pronunciation check opens the mic when viewing a word to verify your pronunciation.")
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
                                .foregroundStyle(AyyatColors.textSecondary)
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
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                    HStack {
                        Text("Quran Data")
                        Spacer()
                        Text("Quran Foundation API")
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }

                // Powered by section at bottom
                Section {
                    VStack(spacing: 12) {
                        Text("Voice Recognition")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AyyatColors.textSecondary)

                        HStack(spacing: 20) {
                            // Apple
                            HStack(spacing: 6) {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 16))
                                Text("Speech")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(AyyatColors.textPrimary)

                            Text("+")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))

                            // Tarteel
                            HStack(spacing: 6) {
                                Image("TarteelLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 14)
                                Text("Tarteel AI")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(AyyatColors.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showGoalSheet) {
                GoalSheet()
                    .presentationDetents([.medium])
            }
        }
    }
}

// MARK: - Voice AI Settings Page

struct VoiceAISettingsView: View {
    @Environment(SettingsManager.self) private var settings
    private var checker: PronunciationChecker { SharedPronunciationChecker.checker }

    var body: some View {
        @Bindable var settingsBindable = settings
        ScrollView {
            VStack(spacing: 24) {
                // Status Card
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: checker.isModelLoaded
                                        ? [AyyatColors.mastered, AyyatColors.mastered.opacity(0.8)]
                                        : [AyyatColors.primary, AyyatColors.primary.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                            .shadow(color: (checker.isModelLoaded ? AyyatColors.mastered : AyyatColors.primary).opacity(0.3), radius: 12, y: 4)

                        if checker.isModelLoading {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: checker.isModelLoaded ? "waveform" : "waveform.slash")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(spacing: 6) {
                        Text(checker.isModelLoaded ? "Ready" : checker.isModelLoading ? "Preparing..." : "Offline")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AyyatColors.textPrimary)

                        Text("Works completely offline")
                            .font(.system(size: 13))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }

                    if checker.isModelLoading {
                        ProgressView(value: checker.loadingProgress)
                            .tint(AyyatColors.primary)
                            .frame(maxWidth: 200)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Powered By Card
                VStack(spacing: 16) {
                    Text("POWERED BY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
                        .tracking(1.2)

                    HStack(spacing: 20) {
                        // Apple
                        HStack(spacing: 6) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 16))
                            Text("Speech")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(AyyatColors.textPrimary)

                        // Divider
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AyyatColors.textSecondary.opacity(0.2))
                            .frame(width: 1, height: 20)

                        // Tarteel
                        HStack(spacing: 6) {
                            Image("TarteelLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 12)
                            Text("Tarteel AI")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(AyyatColors.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.horizontal, 16)

                // Info text
                Text("Dual AI engines verify your pronunciation with word-level precision. The full model runs on your device for privacy and speed.")
                    .font(.system(size: 13))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                // Engine selection — Quran model + optional Apple Speech.
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Use FastConformer-Quran (experimental)", isOn: $settingsBindable.useFastConformer)
                            .tint(AyyatColors.primary)
                        Text("Custom CTC model trained in-house. Restart the app after toggling. The engine loads at startup.")
                            .font(.system(size: 12))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.horizontal, 16)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Voice AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(AyyatColors.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

struct FeatureRowClean: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AyyatColors.textPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

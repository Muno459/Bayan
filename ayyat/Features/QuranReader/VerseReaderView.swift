import SwiftUI

struct VerseReaderView: View {
    let chapter: Chapter

    @Environment(QuranStore.self) private var quranStore
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(AudioPlaybackManager.self) private var audioManager
    @Environment(SettingsManager.self) private var settings
    @Environment(UserStore.self) private var userStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var showSubstitutionControls = false
    @State private var showChapterInfo = false
    @State private var scrollPosition: String?
    @State private var currentMilestone: VocabularyMilestone?
    @State private var isWarmedUp = false
    @State private var trackedVerses: Set<Int> = [] // Prevent duplicate exposure tracking

    // Memorize Mode (Hifz) — operates at the *surah* level, not per-verse.
    // The slider hides a deterministic random subset of words across all
    // verses of the current surah; tapping a hidden word peeks it for 2s.
    @State private var hifzMode = false
    @State private var hifzRevealLevel: Double = 1.0  // 1.0 = nothing hidden
    @State private var hifzHiddenWordIds: Set<Int> = []
    @State private var hifzTemporarilyRevealed: Set<Int> = []
    @State private var hifzPeekTasks: [Int: Task<Void, Never>] = [:]

    // Owned Task handles so we can cancel everything on view dismissal.
    // Without these, scrolling a long surah leaks one Task per visible verse,
    // each holding a 3s sleep and a reference to vocabularyStore.
    @State private var exposureTasks: [Int: Task<Void, Never>] = [:]
    @State private var milestoneTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Memorize Mode control bar — slides in below the toolbar
                if hifzMode {
                    HifzControlBar(
                        revealLevel: $hifzRevealLevel,
                        hiddenCount: hifzHiddenWordIds.count,
                        totalWords: totalWordCountInSurah
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Main content
                Group {
                    if quranStore.isLoadingVerses {
                        loadingView
                    } else if let error = quranStore.error {
                        errorView(error)
                    } else {
                        verseScrollView
                    }
                }

                // Floating audio player — only show once the user has
                // actually triggered playback. The background prefetch on
                // chapter open sets `isLoading` briefly, which used to
                // make the bar pop up as soon as you entered a surah even
                // though no one was playing yet. Drop the `isLoading`
                // branch so the bar only appears once `currentVerseKey`
                // is set.
                if audioManager.currentVerseKey != nil {
                    AudioPlayerBar(chapterId: chapter.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Milestone celebration overlay
            if let milestone = currentMilestone {
                MilestoneOverlay(milestone: milestone)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .background(colorScheme == .dark ? AyyatColors.readerBackgroundDark : AyyatColors.readerBackground)
        .navigationTitle(chapter.nameSimple)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chapter.nameSimple)
                        .font(.system(size: 15, weight: .semibold))
                    Text(chapter.nameArabic)
                        .font(BayanFonts.arabic(14))
                        .foregroundStyle(AyyatColors.textSecondary)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showChapterInfo = true
                    } label: {
                        Label("About this Surah", systemImage: "info.circle")
                    }

                    Button {
                        showSubstitutionControls = true
                    } label: {
                        Label("Substitution Level", systemImage: "textformat.abc")
                    }

                    Button {
                        Task {
                            do {
                                let audioFile = try await quranStore.fetchAudio(for: chapter.id, reciterId: settings.selectedReciterId)
                                await audioManager.loadAudio(audioFile: audioFile, chapterId: chapter.id)
                                audioManager.play()
                            } catch {
                                audioManager.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Play Audio", systemImage: "play.fill")
                    }

                    Divider()

                    Toggle(isOn: $hifzMode.animation(.easeInOut(duration: 0.25))) {
                        Label("Memorize Mode", systemImage: hifzMode ? "brain.head.profile.fill" : "brain.head.profile")
                    }

                    Divider()

                    // Font size — scales both Arabic and translation proportionally
                    Section("Text size") {
                        Button {
                            settings.arabicFontSize = max(20, settings.arabicFontSize - 2)
                            settings.translationFontSize = max(11, settings.translationFontSize - 1)
                        } label: {
                            Label("Smaller", systemImage: "textformat.size.smaller")
                        }
                        Button {
                            settings.arabicFontSize = min(40, settings.arabicFontSize + 2)
                            settings.translationFontSize = min(22, settings.translationFontSize + 1)
                        } label: {
                            Label("Larger", systemImage: "textformat.size.larger")
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { settings.showFullTranslation },
                        set: { settings.showFullTranslation = $0 }
                    )) {
                        Label("Show translation", systemImage: "text.alignleft")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // No in-app color scheme override. iOS Settings → Display already
        // owns this; applying `.preferredColorScheme` here (even gated)
        // bled into the navigation hierarchy and pinned the reader to
        // an old appearance after navigating in.
        // Memorize Mode: rebuild the hidden-word set whenever the toggle,
        // the slider, or the underlying verse data changes. The same seed
        // (chapter id) is used every time so a given chapter always
        // shuffles into the same hide order — feels stable to the user.
        .onChange(of: hifzMode) { _, isOn in
            if isOn {
                recomputeHifzHidden()
            } else {
                hifzHiddenWordIds.removeAll()
                hifzTemporarilyRevealed.removeAll()
                hifzPeekTasks.values.forEach { $0.cancel() }
                hifzPeekTasks.removeAll()
                hifzRevealLevel = 1.0
            }
        }
        .onChange(of: hifzRevealLevel) { _, _ in
            if hifzMode { recomputeHifzHidden() }
        }
        .onChange(of: quranStore.currentVerses.count) { _, _ in
            // Verses (re)loaded — refresh the hide set against the new list.
            if hifzMode { recomputeHifzHidden() }
        }
        .sheet(isPresented: $showSubstitutionControls) {
            SubstitutionControlsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChapterInfo) {
            ChapterInfoSheet(chapter: chapter)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Tie load + session start to chapter identity so unrelated
        // SwiftUI rebuilds (vocabulary store updates, etc.) don't cancel
        // mid-load or fire startSession() a second time. `.onAppear`
        // alone fires every time a presented sheet dismisses, which
        // previously truncated and re-started the reading session on
        // every settings tap — corrupting the streak / goal counts.
        .task(id: chapter.id) {
            userStore.startSession(chapterId: chapter.id, verseKey: "\(chapter.id):1")
            userStore.lastReadChapterId = chapter.id

            // Push now-playing metadata so when the user hits Play (or
            // starts via Lock Screen / Control Center) the chapter name
            // and reciter appear correctly on the OS now-playing UI.
            audioManager.nowPlayingTitle = chapter.nameSimple
            audioManager.nowPlayingReciter = quranStore.reciters
                .first(where: { $0.id == settings.selectedReciterId })?.name

            await quranStore.loadVerses(for: chapter)

            // Background prefetch — fire the audio file fetch + buffer
            // so the very first Play tap (or Lock Screen play command)
            // has no wait. Skip if we're already loaded for this chapter.
            if audioManager.loadedChapterId != chapter.id {
                Task.detached(priority: .utility) { [weak audioManager, chapterId = chapter.id] in
                    guard let audioManager else { return }
                    do {
                        let file = try await quranStore.fetchAudio(
                            for: chapterId,
                            reciterId: settings.selectedReciterId
                        )
                        // Re-check on main: user may have left the chapter
                        // before the fetch completed; don't overwrite an
                        // unrelated player.
                        await MainActor.run {
                            if audioManager.loadedChapterId != chapterId {
                                Task { await audioManager.loadAudio(audioFile: file, chapterId: chapterId) }
                            }
                        }
                    } catch {
                        // Silent — user can still tap Play; we'll fetch then.
                    }
                }
            }

            // Scroll to last read position if returning to same surah
            if userStore.lastReadChapterId == chapter.id,
               let lastVerse = userStore.lastReadVerseKey {
                try? await Task.sleep(for: .milliseconds(300))
                scrollPosition = lastVerse
            }
            // Suppress milestones for 5 seconds after opening
            try? await Task.sleep(for: .seconds(5))
            isWarmedUp = true
        }
        .onDisappear {
            audioManager.stop() // Stop audio before view deallocates
            userStore.endCurrentSession(lastVerseKey: scrollPosition)
            if let pos = scrollPosition {
                userStore.lastReadVerseKey = pos
            }
            // Cancel every still-pending task that captured @State so they
            // can't fire on a torn-down view.
            milestoneTask?.cancel()
            for (_, task) in exposureTasks { task.cancel() }
            exposureTasks.removeAll()
            for (_, task) in hifzPeekTasks { task.cancel() }
            hifzPeekTasks.removeAll()
        }
        .onChange(of: audioManager.currentVerseKey) { _, newValue in
            if let key = newValue {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollPosition = key
                }
            }
        }
        .onChange(of: vocabularyStore.familiarCount) { oldVal, newVal in
            guard isWarmedUp else { return }
            if let milestone = VocabularyMilestone.check(oldCount: oldVal, newCount: newVal) {
                withAnimation { currentMilestone = milestone }
                // Replace any in-flight dismiss task so two milestones in
                // quick succession don't have their timers stomp each other.
                milestoneTask?.cancel()
                milestoneTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation { currentMilestone = nil }
                }
            }
        }
    }

    // MARK: - Verse Scroll View

    private var verseScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Bismillah header (for all surahs except At-Tawbah)
                if chapter.id != 9 {
                    bismillahHeader
                }

                ForEach(quranStore.currentVerses) { verse in
                    VerseCell(
                        verse: verse,
                        isCurrentVerse: audioManager.currentVerseKey == verse.verseKey,
                        currentWordIndex: audioManager.currentVerseKey == verse.verseKey
                            ? audioManager.currentWordIndex : nil,
                        onPlayVerse: {
                            Task {
                                if !audioManager.isReady {
                                    // Load audio first
                                    do {
                                        let audioFile = try await quranStore.fetchAudio(for: chapter.id, reciterId: settings.selectedReciterId)
                                        await audioManager.loadAudio(audioFile: audioFile, chapterId: chapter.id)
                                    } catch {
                                        audioManager.error = error.localizedDescription
                                        return
                                    }
                                }
                                audioManager.seekToVerse(verse.verseKey)
                                audioManager.play()
                            }
                        },
                        hifzHiddenWordIds: hifzHiddenWordIds,
                        hifzTemporarilyRevealed: hifzTemporarilyRevealed,
                        onPeekWord: peekHifzWord
                    )
                    .id(verse.verseKey)
                    .onAppear {
                        let words = verse.words
                        let verseId = verse.id
                        // Already recorded this session — don't bother
                        // scheduling another sleep.
                        guard !trackedVerses.contains(verseId),
                              exposureTasks[verseId] == nil
                        else { return }
                        exposureTasks[verseId] = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            trackedVerses.insert(verseId)
                            if let words {
                                vocabularyStore.recordExposures(for: words)
                            }
                            exposureTasks[verseId] = nil
                        }
                    }
                    .onDisappear {
                        // Cancel the 3s exposure timer when a verse scrolls
                        // off the screen before it fires. Re-appearing
                        // restarts a fresh timer via .onAppear.
                        exposureTasks[verse.id]?.cancel()
                        exposureTasks[verse.id] = nil
                    }
                }

                // Bottom spacer for audio player
                Color.clear.frame(height: 100)
            }
        }
        .scrollPosition(id: $scrollPosition, anchor: .center)
    }

    // MARK: - Bismillah Header

    private var bismillahHeader: some View {
        VStack(spacing: BayanSpacing.md) {
            // Decorative line
            HStack {
                decorativeLine
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(AyyatColors.gold)
                decorativeLine
            }
            .padding(.horizontal, BayanSpacing.xl)

            // Respect the user's learning track for the bismillah header:
            // transliteration mode users haven't opted into Arabic script
            // and shouldn't be shown raw Uthmani as the chapter banner.
            if vocabularyStore.useTransliteration {
                Text("Bismillāh ir-Raḥmān ir-Raḥīm")
                    .font(.system(size: settings.arabicFontSize - 2, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(AyyatColors.textArabic)
                    .multilineTextAlignment(.center)
            } else {
                Text("بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ")
                    .font(BayanFonts.arabic(settings.arabicFontSize + 2))
                    .foregroundStyle(AyyatColors.textArabic)
                    .multilineTextAlignment(.center)
                    .lineSpacing(12)
            }

            Text("In the name of Allah, the Most Gracious, the Most Merciful")
                .font(BayanFonts.caption)
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)

            HStack {
                decorativeLine
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(AyyatColors.gold)
                decorativeLine
            }
            .padding(.horizontal, BayanSpacing.xl)
        }
        .padding(.vertical, BayanSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    private var decorativeLine: some View {
        Rectangle()
            .fill(AyyatColors.gold.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: BayanSpacing.md) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading \(chapter.nameSimple)...")
                .font(BayanFonts.body)
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Unable to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") {
                Task { await quranStore.loadVerses(for: chapter) }
            }
            .buttonStyle(.borderedProminent)
            .tint(AyyatColors.primary)
        }
    }

    // MARK: - Memorize Mode helpers

    /// Total word count across every verse currently loaded in the surah.
    private var totalWordCountInSurah: Int {
        quranStore.currentVerses.reduce(0) { acc, verse in
            acc + (verse.words?.filter(\.isWord).count ?? 0)
        }
    }

    /// Compute the set of word ids hidden right now based on
    /// `hifzRevealLevel` and a stable per-surah random order.
    private func recomputeHifzHidden() {
        let allWords = quranStore.currentVerses
            .flatMap { $0.words?.filter(\.isWord) ?? [] }
        guard !allWords.isEmpty else {
            hifzHiddenWordIds = []
            return
        }
        let hideCount = Int(round(Double(allWords.count) * (1 - hifzRevealLevel)))
        guard hideCount > 0 else {
            hifzHiddenWordIds = []
            return
        }
        // Seeded shuffle so the same surah always picks the same hide
        // order; FNV-1a hash of chapter id gives a stable seed.
        let seed = stableSeed(forChapterId: chapter.id)
        let shuffled = seededShuffle(allWords, seed: seed)
        hifzHiddenWordIds = Set(shuffled.prefix(hideCount).map(\.id))
    }

    /// Peek a hidden word for 2 s, then re-hide. Cancels any in-flight
    /// re-hide for the same word so rapid taps don't stack.
    private func peekHifzWord(_ wordId: Int) {
        hifzTemporarilyRevealed.insert(wordId)
        hifzPeekTasks[wordId]?.cancel()
        hifzPeekTasks[wordId] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                _ = hifzTemporarilyRevealed.remove(wordId)
            }
            hifzPeekTasks[wordId] = nil
        }
    }

    private func stableSeed(forChapterId id: Int) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in String(id).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }

    private func seededShuffle<T>(_ items: [T], seed: UInt64) -> [T] {
        var rng = XorshiftRNG(seed: seed)
        var array = items
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            array.swapAt(i, j)
        }
        return array
    }

    private struct XorshiftRNG {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }
}

/// Slim slider strip that lives at the top of the reader while Memorize
/// Mode is on. Lets the user drag the % of words shown, shows a live
/// "8 / 53 hidden" counter, and offers a one-tap "show all" reset.
private struct HifzControlBar: View {
    @Binding var revealLevel: Double
    let hiddenCount: Int
    let totalWords: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AyyatColors.primary)
                Text("Memorize")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                Spacer()
                if totalWords > 0 {
                    Text("\(hiddenCount) / \(totalWords) hidden")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AyyatColors.textSecondary)
                }
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        revealLevel = 1.0
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AyyatColors.primary)
                }
                .accessibilityLabel("Show all words")
                .disabled(revealLevel >= 0.999)
                .opacity(revealLevel >= 0.999 ? 0.4 : 1)
            }
            Slider(value: $revealLevel, in: 0...1)
                .tint(AyyatColors.primary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            Rectangle()
                .fill(.thinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AyyatColors.textSecondary.opacity(0.15))
                        .frame(height: 0.5)
                }
        )
    }
}

/// Apply `preferredColorScheme` only when the caller passes a concrete
/// scheme. Skips the modifier entirely for `nil` so the view inherits
/// from its environment instead of getting silently pinned to light
/// (a long-standing SwiftUI quirk with `.preferredColorScheme(nil)`).
private struct OptionalPreferredColorScheme: ViewModifier {
    let scheme: ColorScheme?
    init(_ scheme: ColorScheme?) { self.scheme = scheme }
    func body(content: Content) -> some View {
        if let scheme {
            content.preferredColorScheme(scheme)
        } else {
            content
        }
    }
}

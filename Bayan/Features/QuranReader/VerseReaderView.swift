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
    @State private var scrollPosition: String?
    @State private var currentMilestone: VocabularyMilestone?
    @State private var isWarmedUp = false
    @State private var trackedVerses: Set<Int> = [] // Prevent duplicate exposure tracking

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
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

                // Floating audio player
                if audioManager.currentVerseKey != nil || audioManager.isLoading {
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
        .background(colorScheme == .dark ? BayanColors.readerBackgroundDark : BayanColors.readerBackground)
        .navigationTitle(chapter.nameSimple)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chapter.nameSimple)
                        .font(.system(size: 15, weight: .semibold))
                    Text(chapter.nameArabic)
                        .font(BayanFonts.arabic(14))
                        .foregroundStyle(BayanColors.textSecondary)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showSubstitutionControls = true
                    } label: {
                        Label("Substitution Level", systemImage: "textformat.abc")
                    }

                    Button {
                        Task {
                            do {
                                let audioFile = try await quranStore.fetchAudio(for: chapter.id, reciterId: settings.selectedReciterId)
                                await audioManager.loadAudio(audioFile: audioFile)
                                audioManager.play()
                            } catch {
                                audioManager.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Play Audio", systemImage: "play.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSubstitutionControls) {
            SubstitutionControlsSheet()
                .presentationDetents([.medium, .large])
        }
        .task {
            await quranStore.loadVerses(for: chapter)
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
        .onAppear {
            userStore.startSession(chapterId: chapter.id, verseKey: "\(chapter.id):1")
            userStore.lastReadChapterId = chapter.id
        }
        .onDisappear {
            audioManager.stop() // Stop audio before view deallocates
            userStore.endCurrentSession()
            if let pos = scrollPosition {
                userStore.lastReadVerseKey = pos
            }
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
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
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
                                if audioManager.currentVerseKey == nil {
                                    // Load audio first if not loaded
                                    do {
                                        let audioFile = try await quranStore.fetchAudio(for: chapter.id, reciterId: settings.selectedReciterId)
                                        await audioManager.loadAudio(audioFile: audioFile)
                                    } catch {
                                        audioManager.error = error.localizedDescription
                                        return
                                    }
                                }
                                audioManager.seekToVerse(verse.verseKey)
                                audioManager.play()
                            }
                        }
                    )
                    .id(verse.verseKey)
                    .onAppear {
                        // Track which verses are visible, record exposure only for current verse
                        let words = verse.words
                        let verseId = verse.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            // Only count if we haven't already tracked this verse this session
                            guard !trackedVerses.contains(verseId) else { return }
                            trackedVerses.insert(verseId)
                            if let words {
                                for word in words {
                                    vocabularyStore.recordExposure(for: word)
                                }
                            }
                        }
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
                    .foregroundStyle(BayanColors.gold)
                decorativeLine
            }
            .padding(.horizontal, BayanSpacing.xl)

            Text("بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ")
                .font(BayanFonts.arabic(settings.arabicFontSize + 2))
                .foregroundStyle(BayanColors.textArabic)
                .multilineTextAlignment(.center)
                .lineSpacing(12)

            Text("In the name of Allah, the Most Gracious, the Most Merciful")
                .font(BayanFonts.caption)
                .foregroundStyle(BayanColors.textSecondary)
                .multilineTextAlignment(.center)

            HStack {
                decorativeLine
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(BayanColors.gold)
                decorativeLine
            }
            .padding(.horizontal, BayanSpacing.xl)
        }
        .padding(.vertical, BayanSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    private var decorativeLine: some View {
        Rectangle()
            .fill(BayanColors.gold.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: BayanSpacing.md) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading \(chapter.nameSimple)...")
                .font(BayanFonts.body)
                .foregroundStyle(BayanColors.textSecondary)
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
            .tint(BayanColors.primary)
        }
    }
}

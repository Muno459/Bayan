import SwiftUI

struct ChapterListView: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(UserStore.self) private var userStore
    @Environment(VocabularyStore.self) private var vocabularyStore
    @AppStorage("hasSeenWordTip") private var hasSeenWordTip = false
    @State private var searchText = ""
    @State private var showQuranSearch = false
    @State private var pendingNavigation: PendingNavigation?

    struct PendingNavigation: Hashable {
        let chapterId: Int
        let verseKey: String
    }

    private var filteredChapters: [Chapter] {
        if searchText.isEmpty {
            return quranStore.chapters
        }
        return quranStore.chapters.filter {
            $0.nameSimple.localizedCaseInsensitiveContains(searchText) ||
            $0.nameArabic.contains(searchText) ||
            "\($0.id)" == searchText
        }
    }

    var body: some View {
        Group {
            if quranStore.isLoadingChapters || (quranStore.chapters.isEmpty && quranStore.error == nil) {
                chapterSkeletons
            } else if let error = quranStore.error {
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await quranStore.loadChapters() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AyyatColors.primary)
                }
            } else {
                List {
                    // Daily ayah — the only hero card on the home screen.
                    // Doubles as the bismillah surrogate (it's a verse with
                    // tap-to-learn already wired) so we don't need a
                    // separate decorative bismillah section.
                    Section {
                        DailyAyahCard()
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    // Continue Reading — only appears when the user has
                    // somewhere to continue, so the home is uncluttered
                    // for first-launch users.
                    if let chapterId = userStore.lastReadChapterId {
                        let chapterName = quranStore.chapters.first(where: { $0.id == chapterId })?.nameSimple ?? "Surah \(chapterId)"
                        let verseDisplay = userStore.lastReadVerseKey ?? "\(chapterId):1"
                        Section {
                            NavigationLink(value: chapterId) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Continue Reading")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AyyatColors.textSecondary)
                                        Text("\(chapterName) · \(verseDisplay)")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(AyyatColors.primary)
                                }
                            }
                        }
                    }

                    // Chapters
                    Section {
                        ForEach(filteredChapters) { chapter in
                            NavigationLink(value: chapter.id) {
                                chapterRow(chapter)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationDestination(for: Int.self) { chapterId in
                    if let chapter = quranStore.chapters.first(where: { $0.id == chapterId }) {
                        VerseReaderView(chapter: chapter)
                    }
                }
            }
        }
        .navigationTitle("Quran")
        .searchable(text: $searchText, prompt: "Search surahs...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showQuranSearch = true
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .accessibilityLabel("Search verses across the Quran")
            }
        }
        .sheet(isPresented: $showQuranSearch) {
            SearchView { chapterId, verseKey in
                pendingNavigation = PendingNavigation(chapterId: chapterId, verseKey: verseKey)
                userStore.lastReadVerseKey = verseKey
                userStore.lastReadChapterId = chapterId
            }
        }
        .navigationDestination(item: $pendingNavigation) { nav in
            if let chapter = quranStore.chapters.first(where: { $0.id == nav.chapterId }) {
                VerseReaderView(chapter: chapter)
            }
        }
    }

    // MARK: - Skeleton placeholders (visible during cold open)

    private var chapterSkeletons: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<10, id: \.self) { _ in
                    HStack(spacing: 14) {
                        Circle()
                            .fill(AyyatColors.textSecondary.opacity(0.12))
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBar(width: 140, height: 14)
                            SkeletonBar(width: 90, height: 10)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 20)
        }
        .shimmer()
    }

    // MARK: - Chapter Row

    private func chapterRow(_ chapter: Chapter) -> some View {
        HStack(spacing: 14) {
            // Number in diamond
            ZStack {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(AyyatColors.primary.opacity(0.12))
                Text("\(chapter.id)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AyyatColors.primary)
            }
            .frame(width: 40, height: 40)

            // Name + meta
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.nameSimple)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let place = chapter.revelationPlace {
                        Text(place.capitalized)
                    }
                    Text("·")
                    Text("\(chapter.versesCount) ayahs")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Read indicator + Arabic name
            VStack(alignment: .trailing, spacing: 2) {
                Text(chapter.nameArabic)
                    .font(.system(size: 20))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if hasRead(chapter.id) {
                    Text("Read")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AyyatColors.mastered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func hasRead(_ chapterId: Int) -> Bool {
        userStore.sessions.contains { $0.chapterId == chapterId }
    }
}

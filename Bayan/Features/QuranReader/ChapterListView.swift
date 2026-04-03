import SwiftUI

struct ChapterListView: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(UserStore.self) private var userStore
    @AppStorage("hasSeenWordTip") private var hasSeenWordTip = false
    @State private var searchText = ""

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
            if quranStore.isLoadingChapters {
                ProgressView("Loading the Quran...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .tint(BayanColors.primary)
                }
            } else {
                List {
                    // Bismillah hero
                    Section {
                        VStack(spacing: 8) {
                            Text("بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ")
                                .font(.system(size: 26, design: .serif))
                                .foregroundStyle(BayanColors.primary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)

                            Text("Begin your journey with the Quran")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                    }

                    // Continue Reading
                    if let chapterId = userStore.lastReadChapterId {
                        let chapterName = quranStore.chapters.first(where: { $0.id == chapterId })?.nameSimple ?? "Surah \(chapterId)"
                        let verseDisplay = userStore.lastReadVerseKey ?? "\(chapterId):1"
                        Section {
                            NavigationLink(value: chapterId) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Continue Reading")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(BayanColors.textSecondary)
                                        Text("\(chapterName) - \(verseDisplay)")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(BayanColors.primary)
                                }
                            }
                        }
                    }

                    // First-time tip
                    if !hasSeenWordTip {
                        Section {
                            HStack(spacing: 12) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(BayanColors.gold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Tap Arabic Words to Learn")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("When you see green Arabic words, tap them to hear pronunciation and see meaning.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(BayanColors.textSecondary)
                                }
                                Button {
                                    hasSeenWordTip = true
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12))
                                        .foregroundStyle(BayanColors.textSecondary)
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
    }

    // MARK: - Chapter Row

    private func chapterRow(_ chapter: Chapter) -> some View {
        HStack(spacing: 14) {
            // Number in diamond
            ZStack {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(BayanColors.primary.opacity(0.12))
                Text("\(chapter.id)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(BayanColors.primary)
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

            // Arabic name
            Text(chapter.nameArabic)
                .font(.system(size: 20, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
    }
}

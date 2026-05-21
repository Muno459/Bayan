import SwiftUI

/// Lists the user's bookmarked verses (local + remote-merged via the
/// Quran Foundation User API when signed in).
struct BookmarksListView: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(UserStore.self) private var userStore
    @Environment(OIDCAuthService.self) private var auth
    @Environment(AppNavigation.self) private var nav

    let onSelect: (Int, String) -> Void   // (chapterId, verseKey)

    var body: some View {
        Group {
            if userStore.bookmarks.isEmpty {
                ContentUnavailableView(
                    "No bookmarks yet",
                    systemImage: "bookmark",
                    description: Text("Tap the bookmark icon on any verse to save it for later.")
                )
            } else {
                List {
                    // Collections entry point — only shown when signed in
                    // since collections are server-side only.
                    if auth.isSignedIn {
                        Section {
                            NavigationLink {
                                CollectionsListView()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(AyyatColors.primary.opacity(0.12))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "tray.full.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(AyyatColors.primary)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Collections")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(AyyatColors.textPrimary)
                                        Text("Organize bookmarks by theme")
                                            .font(.system(size: 12))
                                            .foregroundStyle(AyyatColors.textSecondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    Section {
                        ForEach(userStore.bookmarks.sorted(by: { $0.createdAt > $1.createdAt })) { bookmark in
                            // Tapping a bookmark switches to the Read tab
                            // and pushes the chapter onto its NavigationStack
                            // via the cross-tab `AppNavigation` coordinator.
                            // This is the right UX — bookmarks are a
                            // jump-to-reading shortcut, not a drill-down
                            // within Learn.
                            Button {
                                onSelect(bookmark.chapterId, bookmark.verseKey)
                                nav.openInRead(chapterId: bookmark.chapterId)
                            } label: {
                                bookmarkRow(bookmark)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        if auth.isSignedIn {
                            Text("\(userStore.bookmarks.count) bookmark\(userStore.bookmarks.count == 1 ? "" : "s"). Synced to your Quran.com account.")
                        } else {
                            Text("\(userStore.bookmarks.count) bookmark\(userStore.bookmarks.count == 1 ? "" : "s"). Sign in to sync across devices.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.large)
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AyyatColors.gold.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.gold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chapterName(for: bookmark.chapterId))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                HStack(spacing: 6) {
                    Text(bookmark.verseKey)
                        .monospacedDigit()
                    Text("·")
                    Text(relativeDate(bookmark.createdAt))
                }
                .font(.system(size: 12))
                .foregroundStyle(AyyatColors.textSecondary)
            }
            Spacer()
            // Use a "jump to" arrow rather than a disclosure chevron — the
            // action exits this list and pushes Verse Reader, which is a
            // different intent from "drill into a detail row" that the
            // chevron usually signals.
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private func chapterName(for id: Int) -> String {
        quranStore.chapters.first(where: { $0.id == id })?.nameSimple ?? "Surah \(id)"
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func delete(at offsets: IndexSet) {
        let sorted = userStore.bookmarks.sorted(by: { $0.createdAt > $1.createdAt })
        for index in offsets {
            let bm = sorted[index]
            userStore.toggleBookmark(
                verseKey: bm.verseKey,
                chapterId: bm.chapterId,
                verseNumber: bm.verseNumber
            )
        }
    }
}

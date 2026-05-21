import Foundation
import SwiftUI

/// Central store for Quran content data, injected via @Environment
@MainActor
@Observable
final class QuranStore {
    var chapters: [Chapter] = []
    var reciters: [Reciter] = []
    var currentChapter: Chapter?
    var currentVerses: [Verse] = []
    var isLoadingChapters = false
    var isLoadingVerses = false
    var error: String?

    let apiClient: APIClient

    /// In-flight reciter fetch. Guarded so a re-entry into loadChapters()
    /// (view re-appear, tab switch) doesn't fire a second concurrent fetch
    /// that races to overwrite `reciters` with whichever returns last.
    private var reciterTask: Task<Void, Never>?

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
        dlog("[QuranStore] init")
    }

    // MARK: - Chapters

    func loadChapters() async {
        guard chapters.isEmpty else { return }
        isLoadingChapters = true
        error = nil

        let start = CFAbsoluteTimeGetCurrent()

        // Load from SQLite database (instant)
        do {
            chapters = try QuranDatabase.shared.fetchAllChapters()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            dlog("[QuranStore] ✓ Loaded \(chapters.count) chapters from DB in \(String(format: "%.3f", elapsed))s")
        } catch {
            dlog("[QuranStore] ✗ DB error: \(error)")
            self.error = error.localizedDescription
        }

        // Load reciters from API (non-blocking). Stored in a property so
        // a second call to loadChapters() while the first is still in-flight
        // doesn't fire a parallel fetch that races to overwrite `reciters`.
        if reciters.isEmpty, reciterTask == nil {
            reciterTask = Task { [weak self] in
                guard let self else { return }
                let reciterStart = CFAbsoluteTimeGetCurrent()
                let fetched = (try? await self.apiClient.fetchReciters()) ?? []
                self.reciters = fetched
                self.reciterTask = nil
                dlog("[QuranStore] Reciters loaded: \(fetched.count) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - reciterStart))s")
            }
        }

        isLoadingChapters = false
    }

    // MARK: - Verses

    /// The translation ID currently rendered in `currentVerses`. Tracks
    /// whether the local SQLite data (Saheeh 131) is fresh or whether
    /// we've live-fetched another translation.
    private(set) var loadedTranslationId: Int = 131

    func loadVerses(for chapter: Chapter, translationId: Int? = nil) async {
        let requestedTranslation = translationId ?? 131
        dlog("[QuranStore] loadVerses(chapter: \(chapter.id) - \(chapter.nameSimple)) translation=\(requestedTranslation)")
        currentChapter = chapter
        isLoadingVerses = true
        error = nil

        let start = CFAbsoluteTimeGetCurrent()
        let chapterId = chapter.id

        // SQLite bundles Saheeh International (131) only. For other
        // translations we fetch live from the Content API.
        if requestedTranslation == 131 {
            do {
                let verses = try await Task.detached(priority: .userInitiated) {
                    try QuranDatabase.shared.fetchVerses(forChapter: chapterId)
                }.value
                currentVerses = verses
                loadedTranslationId = 131
                dlog("[QuranStore] ✓ \(verses.count) verses from DB in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))s")
            } catch {
                dlog("[QuranStore] DB error: \(error)")
                self.error = error.localizedDescription
            }
        } else {
            do {
                let response = try await apiClient.fetchVerses(
                    chapterNumber: chapterId,
                    perPage: 300,
                    translationId: requestedTranslation
                )
                currentVerses = response.verses
                loadedTranslationId = requestedTranslation
                dlog("[QuranStore] ✓ \(response.verses.count) verses from API (\(requestedTranslation)) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))s")
            } catch {
                dlog("[QuranStore] API error: \(error)")
                self.error = error.localizedDescription
            }
        }

        isLoadingVerses = false
    }

    /// Re-fetch the current chapter's verses with the given translation.
    /// Called when the user picks a new translation in Settings.
    func reloadVerses(translationId: Int) async {
        guard let chapter = currentChapter, translationId != loadedTranslationId else { return }
        await loadVerses(for: chapter, translationId: translationId)
    }

    /// Back-compat alias for the previous call site.
    func reloadVersesIfNeeded() async {
        guard let chapter = currentChapter else { return }
        await loadVerses(for: chapter, translationId: loadedTranslationId)
    }

    // MARK: - Audio

    func fetchAudio(for chapterNumber: Int, reciterId: Int = 7) async throws -> AudioFile {
        dlog("[QuranStore] fetchAudio(chapter: \(chapterNumber), reciter: \(reciterId))")
        return try await apiClient.fetchAudioWithSegments(reciterId: reciterId, chapterNumber: chapterNumber)
    }
}

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

    /// IDs of reciters whose chapter audio response actually ships a
    /// `timestamps` array. Reciters not in this set play correctly but
    /// can't drive the per-verse / per-word highlight — we hide them
    /// from the picker so the UX stays consistent.
    var reciterIdsWithTimings: Set<Int> = []

    /// `reciters` filtered to those with verified timings. The picker
    /// reads this so the user only sees reciters that highlight along.
    var recitersWithTimings: [Reciter] {
        reciters.filter { reciterIdsWithTimings.contains($0.id) }
    }

    let apiClient: APIClient

    /// In-flight reciter fetch. Guarded so a re-entry into loadChapters()
    /// (view re-appear, tab switch) doesn't fire a second concurrent fetch
    /// that races to overwrite `reciters` with whichever returns last.
    private var reciterTask: Task<Void, Never>?

    /// Background probe that discovers which reciters expose timings.
    private var verifyTask: Task<Void, Never>?

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

                // Hydrate the verified-timings set from cache or kick
                // off a fresh probe.
                self.loadOrProbeReciterTimings()
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
        let requestedTranslation = translationId ?? 20  // Saheeh International on api.quran.com v4
        dlog("[QuranStore] loadVerses(chapter: \(chapter.id) - \(chapter.nameSimple)) translation=\(requestedTranslation)")
        currentChapter = chapter
        isLoadingVerses = true
        error = nil

        let start = CFAbsoluteTimeGetCurrent()
        let chapterId = chapter.id

        // SQLite bundles Saheeh International (translation id 20) only.
        // The bundled DB now stores the full per-verse translation in a
        // verse_translations table, so the reader has proper full
        // sentences with punctuation right out of the box — no API
        // round-trip and no fallback to per-word concatenation. Other
        // translations still fetch live from the Content API.
        if requestedTranslation == 20 {
            do {
                let verses = try await Task.detached(priority: .userInitiated) {
                    try QuranDatabase.shared.fetchVerses(
                        forChapter: chapterId,
                        translationId: 20
                    )
                }.value
                currentVerses = verses
                loadedTranslationId = 20
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

    // MARK: - Reciter timings probe
    //
    // Different reciters in Quran Foundation's catalog ship different
    // levels of timing data. Some return per-verse timestamps + per-word
    // segments (Mishari, Husary, etc.), some return per-verse only, and
    // a few return nothing — for those the highlight bar can't move
    // during playback. Rather than show all 29 and let the user pick a
    // "broken" one, we probe each on first launch and only display the
    // ones that ship at least per-verse timings.
    //
    // Cached for 14 days. Each probe is a single GET to chapter 1.

    private static let cacheKey = "ayyat.reciterIdsWithTimings.v1"
    private static let cacheDateKey = "ayyat.reciterIdsWithTimings.v1.date"
    private static let cacheTTL: TimeInterval = 14 * 24 * 60 * 60

    private func loadOrProbeReciterTimings() {
        let defaults = UserDefaults.standard
        if let cachedDate = defaults.object(forKey: Self.cacheDateKey) as? Date,
           Date().timeIntervalSince(cachedDate) < Self.cacheTTL,
           let cached = defaults.array(forKey: Self.cacheKey) as? [Int]
        {
            self.reciterIdsWithTimings = Set(cached)
            dlog("[QuranStore] Reciter timings from cache: \(cached.count) verified")
            return
        }
        // Seed the picker with Mishari + a couple of well-known reciters
        // so the UI isn't empty while the probe runs.
        self.reciterIdsWithTimings = [7, 6, 1, 4, 3]
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            await self?.probeReciterTimings()
        }
    }

    private func probeReciterTimings() async {
        let start = CFAbsoluteTimeGetCurrent()
        let candidates = reciters.map(\.id)
        guard !candidates.isEmpty else { return }

        let verified = await withTaskGroup(of: Int?.self) { group -> [Int] in
            for id in candidates {
                group.addTask { [apiClient] in
                    do {
                        let file = try await apiClient.fetchAudioWithSegments(
                            reciterId: id, chapterNumber: 1
                        )
                        let hasTimings = (file.timestamps?.isEmpty == false)
                        return hasTimings ? id : nil
                    } catch {
                        return nil
                    }
                }
            }
            var result: [Int] = []
            for await id in group {
                if let id { result.append(id) }
            }
            return result
        }

        let set = Set(verified)
        // Always keep Mishari + Husary as a floor in case the probe
        // hits transient errors on launch.
        let withFloor = set.union([7, 6])
        self.reciterIdsWithTimings = withFloor

        UserDefaults.standard.set(Array(withFloor), forKey: Self.cacheKey)
        UserDefaults.standard.set(Date(), forKey: Self.cacheDateKey)

        dlog("[QuranStore] Reciter timings probed in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s — \(withFloor.count)/\(candidates.count) verified")
    }
}

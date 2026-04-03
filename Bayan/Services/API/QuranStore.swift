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

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func loadChapters() async {
        guard chapters.isEmpty else { return }
        isLoadingChapters = true
        error = nil
        do {
            chapters = try await apiClient.fetchChapters()
            // Load reciters in parallel
            if reciters.isEmpty {
                reciters = (try? await apiClient.fetchReciters()) ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingChapters = false
    }

    func loadVerses(for chapter: Chapter) async {
        currentChapter = chapter
        isLoadingVerses = true
        error = nil
        currentVerses = []
        do {
            // Fetch all verses for the chapter
            var allVerses: [Verse] = []
            var page = 1
            let perPage = 50

            while true {
                let response = try await apiClient.fetchVerses(
                    chapterNumber: chapter.id,
                    page: page,
                    perPage: perPage
                )
                allVerses.append(contentsOf: response.verses)

                if let pagination = response.pagination,
                   page < pagination.totalPages
                {
                    page += 1
                } else {
                    break
                }
            }
            currentVerses = allVerses
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingVerses = false
    }

    func fetchAudio(for chapterNumber: Int, reciterId: Int = 7) async throws -> AudioFile {
        try await apiClient.fetchAudioWithSegments(reciterId: reciterId, chapterNumber: chapterNumber)
    }
}

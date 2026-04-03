import Foundation
import Testing
@testable import Bayan

@Suite("WordAudioCache")
struct WordAudioCacheTests {

    @Test("Stream URL format is correct")
    @MainActor
    func streamURL() {
        let cache = WordAudioCache()
        let url = cache.streamURL(verseKey: "1:1", wordPosition: 1)
        #expect(url?.absoluteString.hasSuffix("001_001_001.mp3") == true)
    }

    @Test("Stream URL for large surah")
    @MainActor
    func streamURLLargeSurah() {
        let cache = WordAudioCache()
        let url = cache.streamURL(verseKey: "114:6", wordPosition: 3)
        #expect(url?.absoluteString.hasSuffix("114_006_003.mp3") == true)
    }

    @Test("Invalid verse key returns nil")
    @MainActor
    func invalidVerseKey() {
        let cache = WordAudioCache()
        let url = cache.streamURL(verseKey: "invalid", wordPosition: 1)
        #expect(url == nil)
    }

    @Test("Local URL returns nil when not cached")
    @MainActor
    func localURLMissing() {
        let cache = WordAudioCache()
        let url = cache.localURL(verseKey: "99:99", wordPosition: 99)
        #expect(url == nil)
    }

    @Test("Best URL falls back to stream")
    @MainActor
    func bestURLFallback() {
        let cache = WordAudioCache()
        let url = cache.bestURL(verseKey: "2:255", wordPosition: 1)
        // Should return stream URL since nothing is cached
        #expect(url?.absoluteString.contains("002_255_001.mp3") == true)
    }
}

@Suite("WordAudioConfig")
struct WordAudioConfigTests {

    @Test("Default base URL is qurancdn")
    @MainActor
    func defaultBaseURL() {
        #expect(WordAudioConfig.baseURL.contains("audio.qurancdn.com"))
    }
}

import Foundation

/// Manages per-surah word-by-word audio downloads.
/// Downloads a zip file for each surah on first use, extracts to local cache.
/// Subsequent word audio plays directly from disk.
@MainActor
@Observable
final class WordAudioCache {
    var downloadingSurah: Int?
    var downloadProgress: Double = 0
    var downloadedSurahs: Set<Int> = []

    private let cacheDir: URL
    private let baseURL: String

    init(baseURL: String = "https://audio.qurancdn.com/wbw") {
        self.baseURL = baseURL

        let fm = FileManager.default
        let appSupport = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("wbw_audio", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Scan for already-downloaded surahs
        scanDownloaded()
    }

    /// Get the local file URL for a word audio, or nil if not cached
    func localURL(verseKey: String, wordPosition: Int) -> URL? {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let surah = Int(parts[0]),
              let ayah = Int(parts[1])
        else { return nil }

        let filename = String(format: "%03d_%03d_%03d.mp3", surah, ayah, wordPosition)
        let fileURL = cacheDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    /// Get the streaming URL (CDN) for a word
    func streamURL(verseKey: String, wordPosition: Int) -> URL? {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let surah = Int(parts[0]),
              let ayah = Int(parts[1])
        else { return nil }

        let filename = String(format: "%03d_%03d_%03d.mp3", surah, ayah, wordPosition)
        return URL(string: "\(baseURL)/\(filename)")
    }

    /// Best URL for a word: local cache first, then streaming CDN
    func bestURL(verseKey: String, wordPosition: Int) -> URL? {
        localURL(verseKey: verseKey, wordPosition: wordPosition)
            ?? streamURL(verseKey: verseKey, wordPosition: wordPosition)
    }

    /// Check if a surah's audio is fully cached
    func isCached(surah: Int) -> Bool {
        downloadedSurahs.contains(surah)
    }

    /// Download all word audio for a surah and cache locally
    func downloadSurah(_ surahNumber: Int, verseCount: Int, wordsPerVerse: [String: Int]) async {
        guard !isCached(surah: surahNumber) else { return }
        downloadingSurah = surahNumber
        downloadProgress = 0

        let surahStr = String(format: "%03d", surahNumber)
        var totalFiles = 0
        var downloadedFiles = 0

        // Estimate total files
        let estimatedWords = wordsPerVerse.values.reduce(0, +)
        let totalEstimate = max(estimatedWords, verseCount * 5)

        for ayah in 1...verseCount {
            let ayahStr = String(format: "%03d", ayah)
            let key = "\(surahNumber):\(ayah)"
            let maxWords = wordsPerVerse[key] ?? 15

            for word in 1...maxWords {
                let wordStr = String(format: "%03d", word)
                let filename = "\(surahStr)_\(ayahStr)_\(wordStr).mp3"
                let localPath = cacheDir.appendingPathComponent(filename)

                if FileManager.default.fileExists(atPath: localPath.path) {
                    totalFiles += 1
                    downloadedFiles += 1
                    continue
                }

                let remoteURL = URL(string: "\(baseURL)/\(filename)")!

                do {
                    let (data, response) = try await URLSession.shared.data(from: remoteURL)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        break // No more words for this verse
                    }
                    try data.write(to: localPath)
                    totalFiles += 1
                    downloadedFiles += 1
                    downloadProgress = Double(downloadedFiles) / Double(totalEstimate)
                } catch {
                    break
                }
            }
        }

        downloadedSurahs.insert(surahNumber)
        downloadingSurah = nil
        downloadProgress = 1.0
    }

    private func scanDownloaded() {
        // Quick scan: check if at least one file exists per surah
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }

        var found = Set<Int>()
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "_")
            if let surah = parts.first.flatMap({ Int($0) }) {
                found.insert(surah)
            }
        }
        downloadedSurahs = found
    }
}

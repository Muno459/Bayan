import Foundation

/// Manages per-surah word-by-word audio downloads.
/// Downloads a zip file per surah from R2, extracts to local cache.
/// Falls back to streaming from CDN for individual words if not cached.
@MainActor
@Observable
final class WordAudioCache {
    var downloadingSurah: Int?
    var downloadProgress: Double = 0
    private(set) var downloadedSurahs: Set<Int> = []

    private let cacheDir: URL
    private let r2BaseURL = "https://pub-28e518d8beea4b8fb9791feeb4933ff9.r2.dev/wbw"
    private let cdnBaseURL = "https://audio.qurancdn.com/wbw"

    init() {
        let fm = FileManager.default
        let appCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = appCache.appendingPathComponent("wbw_audio", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        scanDownloaded()
    }

    // MARK: - URL Resolution

    /// Local file URL if cached, nil otherwise
    func localURL(verseKey: String, wordPosition: Int) -> URL? {
        guard let filename = makeFilename(verseKey: verseKey, wordPosition: wordPosition) else { return nil }
        let fileURL = cacheDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// CDN streaming URL (always available, requires network)
    func streamURL(verseKey: String, wordPosition: Int) -> URL? {
        guard let filename = makeFilename(verseKey: verseKey, wordPosition: wordPosition) else { return nil }
        return URL(string: "\(cdnBaseURL)/\(filename)")
    }

    /// Best URL: local cache first, CDN fallback
    func bestURL(verseKey: String, wordPosition: Int) -> URL? {
        localURL(verseKey: verseKey, wordPosition: wordPosition)
            ?? streamURL(verseKey: verseKey, wordPosition: wordPosition)
    }

    func isCached(surah: Int) -> Bool {
        downloadedSurahs.contains(surah)
    }

    // MARK: - Download Surah (zip from R2)

    /// Download a surah's word audio as a single zip from R2, extract to cache
    func downloadSurah(_ surahNumber: Int, verseCount: Int = 0, wordsPerVerse: [String: Int] = [:]) async {
        guard !isCached(surah: surahNumber) else { return }

        downloadingSurah = surahNumber
        downloadProgress = 0

        let surahStr = String(format: "%03d", surahNumber)
        let zipURL = URL(string: "\(r2BaseURL)/surah_\(surahStr).zip")!

        do {
            // Download zip
            let (tempURL, response) = try await URLSession.shared.download(from: zipURL)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // R2 zip not available — fall back to individual file download
                await downloadSurahIndividual(surahNumber, verseCount: verseCount)
                return
            }

            downloadProgress = 0.5

            // Extract zip to cache directory
            try extractZip(from: tempURL, to: cacheDir)
            try? FileManager.default.removeItem(at: tempURL)

            downloadedSurahs.insert(surahNumber)
            downloadProgress = 1.0
        } catch {
            // Fall back to individual downloads
            await downloadSurahIndividual(surahNumber, verseCount: verseCount)
        }

        downloadingSurah = nil
    }

    // MARK: - Fallback: Individual Downloads

    private func downloadSurahIndividual(_ surahNumber: Int, verseCount: Int) async {
        let surahStr = String(format: "%03d", surahNumber)
        let verses = verseCount > 0 ? verseCount : 300 // max estimate

        var downloaded = 0
        for ayah in 1...verses {
            let ayahStr = String(format: "%03d", ayah)
            for word in 1...30 {
                let wordStr = String(format: "%03d", word)
                let filename = "\(surahStr)_\(ayahStr)_\(wordStr).mp3"
                let localPath = cacheDir.appendingPathComponent(filename)

                if FileManager.default.fileExists(atPath: localPath.path) {
                    downloaded += 1
                    continue
                }

                guard let url = URL(string: "\(cdnBaseURL)/\(filename)") else { break }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { break }
                    try data.write(to: localPath)
                    downloaded += 1
                } catch {
                    break
                }
            }
        }

        if downloaded > 0 {
            downloadedSurahs.insert(surahNumber)
        }
        downloadProgress = 1.0
    }

    // MARK: - Zip Extraction

    private func extractZip(from zipURL: URL, to destDir: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Use built-in unzip via Process (iOS doesn't have /usr/bin/unzip but we can use Foundation)
        // Actually on iOS, use the Archive framework or manual zip parsing
        // For simplicity, use the coordinator-based approach
        try fm.unzipItem(at: zipURL, to: tempDir)

        // Move extracted files to cache
        if let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "mp3" {
                let dest = destDir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeFilename(verseKey: String, wordPosition: Int) -> String? {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let surah = Int(parts[0]),
              let ayah = Int(parts[1])
        else { return nil }
        return String(format: "%03d_%03d_%03d.mp3", surah, ayah, wordPosition)
    }

    private func scanDownloaded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        var found = Set<Int>()
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if let surah = name.split(separator: "_").first.flatMap({ Int($0) }) {
                found.insert(surah)
            }
        }
        downloadedSurahs = found
    }
}

// MARK: - FileManager Zip Extension

extension FileManager {
    /// Extract a zip file to a directory. Uses Foundation's built-in zip support (iOS 16+).
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Read zip file
        let data = try Data(contentsOf: sourceURL)

        // Simple zip extraction — find local file headers and extract
        var offset = 0
        while offset + 30 < data.count {
            // Local file header signature: 0x04034b50
            let sig = data[offset..<offset+4]
            guard sig == Data([0x50, 0x4B, 0x03, 0x04]) else { break }

            let compMethod = UInt16(data[offset+8]) | (UInt16(data[offset+9]) << 8)
            let compSize = UInt32(data[offset+18]) | (UInt32(data[offset+19]) << 8) | (UInt32(data[offset+20]) << 16) | (UInt32(data[offset+21]) << 24)
            let uncompSize = UInt32(data[offset+22]) | (UInt32(data[offset+23]) << 8) | (UInt32(data[offset+24]) << 16) | (UInt32(data[offset+25]) << 24)
            let nameLen = Int(UInt16(data[offset+26]) | (UInt16(data[offset+27]) << 8))
            let extraLen = Int(UInt16(data[offset+28]) | (UInt16(data[offset+29]) << 8))

            let nameStart = offset + 30
            let nameData = data[nameStart..<nameStart+nameLen]
            guard let name = String(data: nameData, encoding: .utf8) else {
                offset += 30 + nameLen + extraLen + Int(compSize)
                continue
            }

            let dataStart = nameStart + nameLen + extraLen
            let fileData: Data

            if compMethod == 0 {
                // Stored (no compression)
                fileData = data[dataStart..<dataStart+Int(uncompSize)]
            } else if compMethod == 8 {
                // Deflated — use built-in decompression
                let compData = data[dataStart..<dataStart+Int(compSize)]
                if let decompressed = try? (compData as NSData).decompressed(using: .zlib) as Data {
                    fileData = decompressed
                } else {
                    offset = dataStart + Int(compSize)
                    continue
                }
            } else {
                offset = dataStart + Int(compSize)
                continue
            }

            // Write file
            let fileName = (name as NSString).lastPathComponent
            if !fileName.isEmpty && !fileName.hasPrefix(".") {
                let destFile = destinationURL.appendingPathComponent(fileName)
                try fileData.write(to: destFile)
            }

            offset = dataStart + Int(compSize)
        }
    }
}

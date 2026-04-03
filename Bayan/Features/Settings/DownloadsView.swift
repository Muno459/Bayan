import SwiftUI

/// Settings page for managing offline audio downloads.
/// Shows download progress, storage usage, and per-surah status.
struct DownloadsView: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(SettingsManager.self) private var settings
    @State private var audioCache = WordAudioCache()
    @State private var isDownloadingAll = false
    @State private var currentDownloadSurah: String?
    @State private var overallProgress: Double = 0
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        List {
            // Storage info
            Section {
                HStack {
                    Label("Storage Used", systemImage: "internaldrive")
                    Spacer()
                    Text(storageUsed)
                        .foregroundStyle(BayanColors.textSecondary)
                }

                HStack {
                    Label("Surahs Downloaded", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(BayanColors.primary)
                    Spacer()
                    Text("\(audioCache.downloadedSurahs.count)/114")
                        .foregroundStyle(BayanColors.textSecondary)
                }
            } header: {
                Text("Word-by-Word Audio")
            } footer: {
                Text("Download word pronunciation audio for offline use. Each surah is downloaded separately.")
            }

            // Download all button
            Section {
                if isDownloadingAll {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(currentDownloadSurah ?? "Downloading...")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text("\(Int(overallProgress * 100))%")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(BayanColors.primary)
                        }

                        ProgressView(value: overallProgress)
                            .tint(BayanColors.primary)

                        Button("Cancel") {
                            isDownloadingAll = false
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        Task { await downloadAll() }
                    } label: {
                        Label(
                            audioCache.downloadedSurahs.count == 114 ? "All Downloaded" : "Download All Surahs",
                            systemImage: audioCache.downloadedSurahs.count == 114 ? "checkmark.circle.fill" : "arrow.down.to.line"
                        )
                        .foregroundStyle(audioCache.downloadedSurahs.count == 114 ? BayanColors.mastered : BayanColors.primary)
                    }
                    .disabled(audioCache.downloadedSurahs.count == 114)
                }
            }

            // Per-surah list
            Section("Individual Surahs") {
                ForEach(quranStore.chapters) { chapter in
                    HStack {
                        // Status icon
                        Image(systemName: audioCache.isCached(surah: chapter.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(audioCache.isCached(surah: chapter.id) ? BayanColors.mastered : BayanColors.unseen)
                            .font(.system(size: 16))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(chapter.nameSimple)
                                .font(.system(size: 15, weight: .medium))
                            Text("\(chapter.versesCount) ayahs")
                                .font(.system(size: 11))
                                .foregroundStyle(BayanColors.textSecondary)
                        }

                        Spacer()

                        if audioCache.downloadingSurah == chapter.id {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if !audioCache.isCached(surah: chapter.id) {
                            Button {
                                Task {
                                    await audioCache.downloadSurah(
                                        chapter.id,
                                        verseCount: chapter.versesCount,
                                        wordsPerVerse: [:]
                                    )
                                    calculateStorage()
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(BayanColors.primary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { calculateStorage() }
    }

    // MARK: - Download All

    private func downloadAll() async {
        isDownloadingAll = true
        overallProgress = 0

        let chapters = quranStore.chapters.filter { !audioCache.isCached(surah: $0.id) }
        let total = chapters.count

        for (index, chapter) in chapters.enumerated() {
            guard isDownloadingAll else { break }

            currentDownloadSurah = "\(chapter.nameSimple) (\(index + 1)/\(total))"
            overallProgress = Double(index) / Double(total)

            await audioCache.downloadSurah(
                chapter.id,
                verseCount: chapter.versesCount,
                wordsPerVerse: [:]
            )
        }

        isDownloadingAll = false
        overallProgress = 1.0
        currentDownloadSurah = nil
        calculateStorage()
    }

    // MARK: - Storage

    private func calculateStorage() {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wbw_audio")

        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            storageUsed = "0 MB"
            return
        }

        var totalBytes: Int64 = 0
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }

        let mb = Double(totalBytes) / (1024 * 1024)
        if mb < 1 {
            storageUsed = String(format: "%.0f KB", Double(totalBytes) / 1024)
        } else if mb < 1024 {
            storageUsed = String(format: "%.1f MB", mb)
        } else {
            storageUsed = String(format: "%.2f GB", mb / 1024)
        }
    }
}

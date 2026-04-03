import AVFoundation
import Foundation

/// Plays individual word pronunciation audio from audio.qurancdn.com.
/// Supports repeat drill mode: normal speed → slow → normal.
@MainActor
@Observable
final class WordAudioPlayer {
    var isPlaying = false
    var isDrilling = false
    var drillStep = 0 // 0 = normal, 1 = slow, 2 = normal again
    var error: String?

    private var player: AVPlayer?
    private var drillTask: Task<Void, Never>?

    /// Play a single word once at normal speed.
    func play(verseKey: String, wordPosition: Int) {
        stop()
        error = nil
        guard let url = wordURL(verseKey: verseKey, wordPosition: wordPosition) else {
            error = "Invalid audio URL"
            return
        }

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        isPlaying = true

        // Watch for playback errors
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.error = "Could not load audio"
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    /// Pronunciation drill: plays the word 3 times.
    /// 1st: normal speed, 2nd: 0.5x slow, 3rd: normal speed
    func drill(verseKey: String, wordPosition: Int) {
        stop()
        isDrilling = true
        drillStep = 0

        drillTask = Task { @MainActor in
            // Step 1: normal speed
            drillStep = 0
            await playAndWait(verseKey: verseKey, wordPosition: wordPosition, rate: 1.0)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            // Step 2: slow
            drillStep = 1
            await playAndWait(verseKey: verseKey, wordPosition: wordPosition, rate: 0.55)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            // Step 3: normal again
            drillStep = 2
            await playAndWait(verseKey: verseKey, wordPosition: wordPosition, rate: 1.0)

            isDrilling = false
            drillStep = 0
        }
    }

    func stop() {
        drillTask?.cancel()
        drillTask = nil
        player?.pause()
        player = nil
        isPlaying = false
        isDrilling = false
        drillStep = 0
    }

    // MARK: - Private

    private func playAndWait(verseKey: String, wordPosition: Int, rate: Float) async {
        guard let url = wordURL(verseKey: verseKey, wordPosition: wordPosition) else { return }

        isPlaying = true
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.rate = rate

        await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume()
            }
            player?.play()
            player?.rate = rate
        }

        isPlaying = false
    }

    private let cache = WordAudioCache()

    private func wordURL(verseKey: String, wordPosition: Int) -> URL? {
        // Try local cache first, fall back to CDN streaming
        return cache.bestURL(verseKey: verseKey, wordPosition: wordPosition)
    }
}

/// Configurable word-by-word audio source.
/// Default: audio.qurancdn.com. Can be switched to R2 bucket later.
/// Word-by-word audio source configuration.
/// Default: Quran CDN. Switch to R2 bucket when ready.
enum WordAudioConfig {
    /// Current audio source
    @MainActor static var baseURL = "https://audio.qurancdn.com/wbw"

    /// R2 bucket (uncomment when files are uploaded)
    // @MainActor static var baseURL = "https://pub-28e518d8beea4b8fb9791feeb4933ff9.r2.dev/wbw"
}

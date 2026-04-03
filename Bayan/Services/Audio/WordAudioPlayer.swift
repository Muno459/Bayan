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

    private func wordURL(verseKey: String, wordPosition: Int) -> URL? {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let surah = Int(parts[0]),
              let ayah = Int(parts[1])
        else { return nil }

        let s = String(format: "%03d", surah)
        let a = String(format: "%03d", ayah)
        let w = String(format: "%03d", wordPosition)

        return URL(string: "https://audio.qurancdn.com/wbw/\(s)_\(a)_\(w).mp3")
    }
}

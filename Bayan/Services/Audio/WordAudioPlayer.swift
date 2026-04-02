import AVFoundation
import Foundation

/// Plays individual word pronunciation audio from audio.qurancdn.com.
/// URL pattern: https://audio.qurancdn.com/wbw/{surah}_{ayah}_{word}.mp3
/// e.g. 023_005_001.mp3 = Surah 23, Verse 5, Word 1
@MainActor
@Observable
final class WordAudioPlayer {
    var isPlaying = false

    private var player: AVPlayer?

    /// Play a single word's pronunciation.
    /// - Parameters:
    ///   - verseKey: e.g. "1:1", "23:5"
    ///   - wordPosition: 1-based word position in the verse
    func play(verseKey: String, wordPosition: Int) {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let surah = Int(parts[0]),
              let ayah = Int(parts[1])
        else { return }

        let surahStr = String(format: "%03d", surah)
        let ayahStr = String(format: "%03d", ayah)
        let wordStr = String(format: "%03d", wordPosition)

        let urlString = "https://audio.qurancdn.com/wbw/\(surahStr)_\(ayahStr)_\(wordStr).mp3"
        guard let url = URL(string: urlString) else { return }

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.play()
        isPlaying = true

        // Observe when playback finishes
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}

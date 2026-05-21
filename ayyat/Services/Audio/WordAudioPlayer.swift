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
    /// Observer tokens for the current AVPlayerItem. Tracked so `stop()`
    /// can detach them before nilling the player — without this, every
    /// `play()` call leaks two observers tied to the previous item, and
    /// drills triple the rate.
    private var itemObservers: [NSObjectProtocol] = []

    /// Play a single word once at normal speed.
    func play(verseKey: String, wordPosition: Int) {
        stop()
        error = nil

        // Ensure audio session is ready for playback
        configureAudioSession()

        guard let url = wordURL(verseKey: verseKey, wordPosition: wordPosition) else {
            error = "Invalid audio URL"
            return
        }

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        isPlaying = true

        // Watch for playback errors. Tokens are captured so we can remove
        // them in stop() — otherwise NotificationCenter strong-refs the
        // closure and every `play()` permanently leaks two observers.
        let failureToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.error = "Could not load audio"
            }
        }
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
        itemObservers = [failureToken, endToken]
    }

    /// Pronunciation drill: plays the word 3 times.
    /// 1st: normal speed, 2nd: 0.5x slow, 3rd: normal speed
    func drill(verseKey: String, wordPosition: Int) {
        stop()
        configureAudioSession()
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
        for token in itemObservers {
            NotificationCenter.default.removeObserver(token)
        }
        itemObservers.removeAll()
        player?.pause()
        player = nil
        isPlaying = false
        isDrilling = false
        drillStep = 0
    }

    // MARK: - Private

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let currentCategory = session.category
        let currentMode = session.mode

        // Only reconfigure if needed
        if currentCategory == .playback && currentMode == .spokenAudio && session.isOtherAudioPlaying == false {
            dlog("[WordAudioPlayer] Audio session already configured, skipping")
            return
        }

        dlog("[WordAudioPlayer] Configuring audio session (was: \(currentCategory.rawValue)/\(currentMode.rawValue))")

        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
            dlog("[WordAudioPlayer] Audio session configured successfully")
        } catch {
            dlog("[WordAudioPlayer] Audio session error: \(error)")
        }
    }

    private func playAndWait(verseKey: String, wordPosition: Int, rate: Float) async {
        guard let url = wordURL(verseKey: verseKey, wordPosition: wordPosition) else { return }

        isPlaying = true
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        player?.rate = rate

        // Wait for playback to finish or timeout
        let startTime = Date()
        while player?.currentItem?.status != .failed {
            // Check if playback finished
            if let currentTime = player?.currentTime(),
               let duration = player?.currentItem?.duration,
               duration.isNumeric && currentTime >= duration {
                break
            }
            // Timeout after 5 seconds
            if Date().timeIntervalSince(startTime) > 5 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        isPlaying = false
    }

    private func wordURL(verseKey: String, wordPosition: Int) -> URL? {
        // Try local cache first, fall back to CDN streaming
        return SharedWordAudioCache.shared.bestURL(verseKey: verseKey, wordPosition: wordPosition)
    }
}


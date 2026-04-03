import AVFoundation
import Foundation
import SwiftUI

/// Manages Quran audio playback with word-level synchronization
@MainActor
@Observable
final class AudioPlaybackManager {
    // MARK: - Observable State

    var isPlaying = false
    var currentVerseKey: String?
    var currentWordIndex: Int?
    var playbackProgress: Double = 0.0
    var isLoading = false
    var error: String?

    // MARK: - Private

    private var player: AVPlayer?
    private var periodicObserver: Any?
    private var boundaryObservers: [Any] = []
    private var wordTimings: [WordTiming] = []
    private var verseTimestamps: [VerseTimestamp] = []

    init() {
        configureAudioSession()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            self.error = "Failed to configure audio session: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback Control

    /// Load and prepare audio for a chapter
    func loadAudio(audioFile: AudioFile) async {
        isLoading = true
        error = nil

        guard let url = URL(string: audioFile.audioUrl) else {
            error = "Invalid audio URL"
            isLoading = false
            return
        }

        // Store timing data
        verseTimestamps = audioFile.timestamps ?? []

        // Flatten all word timings across verses, sorted by start time
        wordTimings = verseTimestamps
            .flatMap { timestamp -> [WordTiming] in
                timestamp.wordTimings
            }
            .sorted { $0.startMs < $1.startMs }

        // Create player
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Observe end of playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }

        setupPeriodicObserver()
        setupBoundaryObservers()

        isLoading = false
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        currentWordIndex = nil
        // Keep currentVerseKey so the UI shows the last verse played
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Play a single word clip by seeking to its start and pausing at its end.
    /// Returns true if word timing was found and playback started.
    func playWordClip(wordPosition: Int) -> Bool {
        // Find the timing for this word position in the current verse
        guard let currentKey = currentVerseKey,
              let verseTs = verseTimestamps.first(where: { $0.verseKey == currentKey })
        else {
            // No active verse — try to find the word in any verse's timings
            return playWordFromAllTimings(wordPosition: wordPosition)
        }

        let timings = verseTs.wordTimings
        guard let wordTiming = timings.first(where: { $0.wordIndex == wordPosition }) else {
            return false
        }

        return playTimingClip(wordTiming)
    }

    private func playWordFromAllTimings(wordPosition: Int) -> Bool {
        // Search all verse timestamps for this word position
        for ts in verseTimestamps {
            if let timing = ts.wordTimings.first(where: { $0.wordIndex == wordPosition }) {
                return playTimingClip(timing)
            }
        }
        return false
    }

    private func playTimingClip(_ timing: WordTiming) -> Bool {
        guard let player else { return false }

        let wasPlaying = isPlaying
        let previousTime = player.currentTime()

        // Seek to word start
        let startTime = CMTime(value: Int64(timing.startMs), timescale: 1000)
        let endTime = CMTime(value: Int64(timing.endMs), timescale: 1000)

        player.seek(to: startTime)
        player.play()

        // Schedule pause at word end
        let endBoundary = [NSValue(time: endTime)]
        let observer = player.addBoundaryTimeObserver(
            forTimes: endBoundary,
            queue: .main
        ) { [weak player] in
            player?.pause()
            // Restore previous state
            if !wasPlaying {
                player?.seek(to: previousTime)
            }
        }

        // Auto-cleanup after 3 seconds max
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            player.removeTimeObserver(observer)
            if !wasPlaying {
                player.pause()
            }
        }

        return true
    }

    func seekToVerse(_ verseKey: String) {
        guard let timestamp = verseTimestamps.first(where: { $0.verseKey == verseKey }) else {
            return
        }
        let time = CMTime(value: Int64(timestamp.timestampFrom), timescale: 1000)
        player?.seek(to: time)
        currentVerseKey = verseKey
    }

    func skipToNextVerse() {
        guard let currentKey = currentVerseKey,
              let currentIdx = verseTimestamps.firstIndex(where: { $0.verseKey == currentKey }),
              currentIdx + 1 < verseTimestamps.count
        else { return }
        let next = verseTimestamps[currentIdx + 1]
        seekToVerse(next.verseKey)
    }

    func skipToPreviousVerse() {
        guard let currentKey = currentVerseKey,
              let currentIdx = verseTimestamps.firstIndex(where: { $0.verseKey == currentKey }),
              currentIdx > 0
        else { return }
        let prev = verseTimestamps[currentIdx - 1]
        seekToVerse(prev.verseKey)
    }

    func setPlaybackSpeed(_ speed: Float) {
        guard isPlaying else { return } // Don't set rate when paused (it auto-plays)
        player?.rate = speed
    }

    func stop() {
        removeObservers()
        if let item = player?.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        player?.pause()
        player = nil
        isPlaying = false
        currentVerseKey = nil
        currentWordIndex = nil
        playbackProgress = 0.0
    }

    // MARK: - Time Observers

    /// Periodic observer at ~30fps for progress tracking and word detection
    private func setupPeriodicObserver() {
        removeObservers()

        let interval = CMTime(value: 1, timescale: 30) // ~33ms
        periodicObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handleTimeUpdate(time)
            }
        }
    }

    /// Register boundary observers at exact word transition points
    private func setupBoundaryObservers() {
        guard !wordTimings.isEmpty else { return }

        let times = wordTimings.map { timing in
            NSValue(time: CMTime(value: Int64(timing.startMs), timescale: 1000))
        }

        let observer = player?.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            Task { @MainActor in
                guard let self, let currentTime = self.player?.currentTime() else { return }
                self.handleTimeUpdate(currentTime)
            }
        }

        if let observer {
            boundaryObservers.append(observer)
        }
    }

    /// Find current verse AND word atomically, update both together
    private func handleTimeUpdate(_ time: CMTime) {
        let currentMs = Int(CMTimeGetSeconds(time) * 1000)

        // Update overall progress
        if let duration = player?.currentItem?.duration,
           !duration.isIndefinite
        {
            let durationMs = CMTimeGetSeconds(duration) * 1000
            playbackProgress = durationMs > 0 ? Double(currentMs) / durationMs : 0
        }

        // Find current verse and word TOGETHER
        var newVerseKey: String?
        var newWordIndex: Int?

        for timestamp in verseTimestamps {
            if currentMs >= timestamp.timestampFrom && currentMs < timestamp.timestampTo {
                newVerseKey = timestamp.verseKey

                // Search for word within THIS verse's segments only
                for timing in timestamp.wordTimings {
                    if currentMs >= timing.startMs && currentMs < timing.endMs {
                        newWordIndex = timing.wordIndex
                        break
                    }
                }
                break
            }
        }

        // Update both atomically — verse key always updates before word index
        if newVerseKey != currentVerseKey {
            currentWordIndex = nil // Clear word first to prevent flash on old verse
            currentVerseKey = newVerseKey
        }
        if newWordIndex != currentWordIndex {
            currentWordIndex = newWordIndex
        }
    }

    private func removeObservers() {
        if let observer = periodicObserver {
            player?.removeTimeObserver(observer)
            periodicObserver = nil
        }
        for observer in boundaryObservers {
            player?.removeTimeObserver(observer)
        }
        boundaryObservers.removeAll()
    }

    deinit {
        // Note: removeObservers() can't be called here since it's @MainActor
        // The player will clean up its own observers when deallocated
    }
}

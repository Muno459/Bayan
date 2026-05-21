import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

/// Manages Quran audio playback with word-level synchronization
@MainActor
@Observable
final class AudioPlaybackManager {
    // MARK: - Observable State

    var isPlaying = false
    /// Whether audio is loaded and ready to play/seek
    var isReady: Bool { player != nil }
    var currentVerseKey: String?
    var currentWordIndex: Int?
    var playbackProgress: Double = 0.0
    var isLoading = false
    var error: String?

    private var lastWordIndex: Int? // Monotonic tracking — prevents backward jumps

    // MARK: - Private

    private var player: AVPlayer?
    private var periodicObserver: Any?
    private var boundaryObservers: [Any] = []
    /// One-shot boundary observers from ad-hoc clip / single-verse plays.
    /// Tracked separately so `removeObservers(from:)` can sweep them up
    /// when the player is replaced, preventing AVFoundation's
    /// "observer not removed before deallocation" exception.
    private var oneShotBoundaryObservers: [Any] = []
    private var wordTimings: [WordTiming] = []
    private var verseTimestamps: [VerseTimestamp] = []
    /// Cached scan position. handleTimeUpdate scans forward from here instead
    /// of from index 0, turning a 286×30 worst-case into amortized O(1) per
    /// 30Hz tick. Reset whenever the user seeks or playback restarts.
    private var lastVerseScanIndex: Int = 0

    /// Now-playing metadata shown on the Lock Screen + Control Center
    /// (via `MPNowPlayingInfoCenter`). Callers (the reader / audio bar)
    /// set these *before* calling `play()`.
    var nowPlayingTitle: String?
    var nowPlayingReciter: String?
    var nowPlayingArtwork: UIImage?
    private var remoteCommandsRegistered = false

    init() {
        // Don't configure audio session on init — do it lazily when needed
        registerRemoteCommandsOnce()
    }

    /// Register Lock Screen play/pause/skip handlers exactly once. Safe to
    /// call multiple times (guarded by `remoteCommandsRegistered`).
    private func registerRemoteCommandsOnce() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToNextVerse() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToPreviousVerse() }
            return .success
        }
    }

    /// Push the current title/reciter/play-state into `MPNowPlayingInfoCenter`
    /// so the Lock Screen and Control Center show the right metadata.
    private func updateNowPlayingInfo() {
        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let title = nowPlayingTitle { info[MPMediaItemPropertyTitle] = title }
        if let reciter = nowPlayingReciter { info[MPMediaItemPropertyArtist] = reciter }
        info[MPMediaItemPropertyAlbumTitle] = "The Holy Quran"
        if let duration = player?.currentItem?.duration,
           duration.isNumeric, !duration.isIndefinite
        {
            info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
        }
        if let currentTime = player?.currentTime() {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(currentTime)
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let artwork = nowPlayingArtwork {
            let mp = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            info[MPMediaItemPropertyArtwork] = mp
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            // Ignore — will retry when actually playing
        }
    }

    // MARK: - Playback Control

    /// The chapter currently loaded into the player, so callers can verify
    /// the audio matches the verse they want to play.
    private(set) var loadedChapterId: Int?

    /// Load and prepare audio for a chapter
    func loadAudio(audioFile: AudioFile, chapterId: Int? = nil) async {
        isLoading = true
        error = nil

        guard let url = URL(string: audioFile.audioUrl) else {
            error = "Invalid audio URL"
            isLoading = false
            return
        }

        // Tear down the previous player BEFORE we replace it, otherwise the
        // periodic / boundary observers stay attached to the old AVPlayer,
        // which can crash on dealloc (NSInvalidArgumentException: An
        // observer was not removed before deallocation).
        if let oldPlayer = player {
            removeObservers(from: oldPlayer)
            if let oldItem = oldPlayer.currentItem {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .AVPlayerItemDidPlayToEndTime,
                    object: oldItem
                )
            }
            oldPlayer.pause()
        }

        // Store timing data
        verseTimestamps = audioFile.timestamps ?? []
        loadedChapterId = chapterId

        // Flatten all word timings across verses, sorted by start time
        wordTimings = verseTimestamps
            .flatMap { timestamp -> [WordTiming] in
                timestamp.wordTimings
            }
            .sorted { $0.startMs < $1.startMs }

        // Create player tuned for fastest start. We don't ask AVURLAsset
        // to compute precise duration (that costs a HEAD + range probe),
        // we cap the lookahead buffer to 2 s instead of 10 s (lower
        // memory + faster first audio sample), and we tell the player
        // not to wait to minimize stalling — playback begins the moment
        // the first decoded sample is available.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2

        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        // Allow short stall windows during network jitter instead of
        // re-buffering from scratch — the user perceives ~50 ms stutter
        // as "audio kept going" whereas a re-buffer feels like a hang.
        if #available(iOS 14.5, *) {
            newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        player = newPlayer
        lastVerseScanIndex = 0

        // Skip the pre-buffer wait entirely on local files (no network
        // load) and for remote URLs let the AVPlayer handle initial
        // buffering itself — the previous up-to-3 s wait was the main
        // reason Play felt sluggish. Audio starts as soon as the first
        // CMSampleBuffer is decoded.
        if url.isFileURL == false {
            // Brief wait so the user doesn't tap Play and get silence
            // for >0.5 s if the network is slow.
            await waitForBuffer(playerItem: playerItem)
        }

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

    /// Wait for initial buffer to fill, observing KVO instead of polling
    /// the main actor every 100 ms. Bails after 3 seconds so a stuck audio
    /// file doesn't deadlock the play button.
    /// Wait for enough initial buffer to start without an immediate
    /// stall. Capped at 1 s so the user never waits longer than that
    /// to hear the first audio — past versions waited up to 3 s.
    private func waitForBuffer(playerItem: AVPlayerItem) async {
        if playerItem.isPlaybackLikelyToKeepUp || playerItem.isPlaybackBufferFull {
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await ready in playerItem.publisher(for: \.isPlaybackLikelyToKeepUp).values {
                    if ready { return }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        currentWordIndex = nil
        // Keep currentVerseKey so the UI shows the last verse played
    }

    func play() {
        configureAudioSession()
        player?.play()
        // Re-apply the user's selected playback speed. AVPlayer resets
        // `rate` to 1.0 on every pause, so a user who set 0.75× and then
        // paused via Lock Screen or by tapping the bar would silently
        // resume at 1.0 without this line.
        if desiredRate != 1.0 {
            player?.rate = desiredRate
        }
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
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

        let capturedPlayer = player
        let slot = oneShotBoundaryObservers.count
        let observer = capturedPlayer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self, weak capturedPlayer] in
            capturedPlayer?.pause()
            if !wasPlaying {
                capturedPlayer?.seek(to: previousTime)
            }
            Task { @MainActor in
                self?.removeOneShotObserver(at: slot, from: capturedPlayer)
            }
        }
        oneShotBoundaryObservers.append(observer)

        // Hard timeout — if the boundary never fires (e.g. AVPlayer rate
        // change before the clip end), we still detach so the observer
        // doesn't outlive its player and crash at dealloc.
        Task { @MainActor [weak self, weak capturedPlayer] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.removeOneShotObserver(at: slot, from: capturedPlayer)
            if !wasPlaying { capturedPlayer?.pause() }
        }

        return true
    }

    /// Play exactly one verse, then stop. Used by Hifz "Listen" and any UI
    /// that wants a single-verse preview rather than playing through the
    /// surah. Uses a boundary observer to pause at the verse's end ms.
    func playSingleVerse(_ verseKey: String) {
        guard let idx = verseTimestamps.firstIndex(where: { $0.verseKey == verseKey }),
              let player else { return }
        lastWordIndex = nil
        lastVerseScanIndex = idx
        let ts = verseTimestamps[idx]
        let startCM = CMTime(value: Int64(ts.timestampFrom), timescale: 1000)
        let endCM = CMTime(value: Int64(ts.timestampTo), timescale: 1000)
        currentVerseKey = verseKey

        let capturedPlayer = player
        // Hop back to the main actor inside the @Sendable seek completion so
        // we can touch @MainActor state (isPlaying) and a non-Sendable
        // observer handle safely under Swift 6 strict concurrency.
        player.seek(to: startCM) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                capturedPlayer.play()
                self.isPlaying = true
                self.installSingleVersePauseBoundary(player: capturedPlayer, at: endCM)
            }
        }
    }

    private func installSingleVersePauseBoundary(player: AVPlayer, at endCM: CMTime) {
        // Reserve the slot first so the callback can find its own index.
        let slot = oneShotBoundaryObservers.count
        let token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endCM)],
            queue: .main
        ) { [weak self, weak player] in
            Task { @MainActor in
                guard let self else { return }
                player?.pause()
                self.isPlaying = false
                self.removeOneShotObserver(at: slot, from: player)
            }
        }
        oneShotBoundaryObservers.append(token)
    }

    /// Detach a one-shot boundary observer after its single fire. We nil
    /// the slot rather than `remove(at:)` so other in-flight observers
    /// keep their captured indices stable.
    private func removeOneShotObserver(at slot: Int, from player: AVPlayer?) {
        guard slot < oneShotBoundaryObservers.count,
              let token = oneShotBoundaryObservers[slot] as Any?
        else { return }
        player?.removeTimeObserver(token)
        // Replace with a tombstone NSNull so the index stays addressable
        // but `removeObservers(from:)` knows to skip it.
        oneShotBoundaryObservers[slot] = NSNull()
    }

    func seekToVerse(_ verseKey: String) {
        lastWordIndex = nil // Reset monotonic tracking on seek
        guard let idx = verseTimestamps.firstIndex(where: { $0.verseKey == verseKey }) else {
            return
        }
        lastVerseScanIndex = idx  // resume scan from this verse, not the cached one
        let timestamp = verseTimestamps[idx]
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

    /// Last requested playback rate. Stored so we can re-apply it
    /// whenever the player resumes — `AVPlayer.rate` resets to 1.0 each
    /// time the player pauses, so just setting it on the live player
    /// isn't enough.
    private var desiredRate: Float = 1.0

    func setPlaybackSpeed(_ speed: Float) {
        desiredRate = speed
        if isPlaying {
            player?.rate = speed
        }
        // Update the lock-screen / Control Center display so the user
        // sees the playback at the new rate.
        updateNowPlayingInfo()
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
        lastWordIndex = nil
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

        // Find current verse + word using a cached forward scan position.
        // Playback advances monotonically, so we resume from the previously
        // matched verse rather than re-scanning all 286 entries.
        var newVerseKey: String?
        var newWordIndex: Int?

        guard !verseTimestamps.isEmpty else { return }
        var i = min(lastVerseScanIndex, verseTimestamps.count - 1)
        // If we've fallen behind the start of cached verse (e.g. seek backward),
        // drop the cache and scan from 0.
        if currentMs < verseTimestamps[i].timestampFrom {
            i = 0
        }
        while i < verseTimestamps.count {
            let ts = verseTimestamps[i]
            if currentMs < ts.timestampFrom {
                break  // not yet at this verse
            }
            if currentMs < ts.timestampTo {
                newVerseKey = ts.verseKey
                for timing in ts.wordTimings {
                    if currentMs >= timing.startMs && currentMs < timing.endMs {
                        newWordIndex = timing.wordIndex
                        break
                    }
                }
                lastVerseScanIndex = i
                break
            }
            i += 1
        }

        // Update both atomically — verse key always updates before word index
        if newVerseKey != currentVerseKey {
            currentWordIndex = nil
            currentVerseKey = newVerseKey
            lastWordIndex = nil
        }

        // Only advance forward within a verse — never jump backward
        // This prevents jitter from AVPlayer timing fluctuations
        if let newIdx = newWordIndex {
            if let lastIdx = lastWordIndex {
                if newIdx >= lastIdx {
                    currentWordIndex = newIdx
                    lastWordIndex = newIdx
                }
                // If newIdx < lastIdx, ignore it (jitter)
            } else {
                currentWordIndex = newIdx
                lastWordIndex = newIdx
            }
        }
    }

    private func removeObservers() {
        removeObservers(from: player)
    }

    /// Same as `removeObservers()` but lets callers detach observers from a
    /// specific player instance (the previous one) before replacing `self.player`.
    private func removeObservers(from p: AVPlayer?) {
        if let observer = periodicObserver {
            p?.removeTimeObserver(observer)
            periodicObserver = nil
        }
        for observer in boundaryObservers {
            p?.removeTimeObserver(observer)
        }
        boundaryObservers.removeAll()
        // Sweep one-shot observers too. Skip tombstones (NSNull) — those
        // already fired and detached themselves. Without this loop, ad-hoc
        // observers from `playTimingClip` / `installSingleVersePauseBoundary`
        // outlive their AVPlayer when `loadAudio` swaps the player mid-clip,
        // and AVFoundation raises NSInvalidArgumentException at dealloc.
        for observer in oneShotBoundaryObservers where !(observer is NSNull) {
            p?.removeTimeObserver(observer)
        }
        oneShotBoundaryObservers.removeAll()
    }

    deinit {
        // Note: removeObservers() can't be called here since it's @MainActor
        // The player will clean up its own observers when deallocated
    }
}

import AVFoundation
import Foundation
import SwiftUI

/// On-device Quranic Arabic pronunciation checker using WhisperKit with Tarteel model.
@MainActor
@Observable
final class PronunciationChecker {
    enum State: Equatable {
        case idle
        case loading
        case recording
        case processing
        case result(correct: Bool, transcription: String)
        case error(String)
    }

    var state: State = .idle
    private(set) var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var whisper: TarteelWhisperKit?
    private var fastConformer: FastConformerQuranASR?
    private let appleSpeech = AppleSpeechRecognizer()  // Instant, no loading
    private(set) var isModelLoaded = false
    private(set) var isModelLoading = false

    /// Read live from UserDefaults so the user can flip the toggle in
    /// Settings between sessions without rebuilding. Default is false
    /// while we validate the in-house FastConformer model on devices.
    private var useFastConformer: Bool {
        UserDefaults.standard.bool(forKey: "useFastConformer")
    }

    /// Apple Speech runs in parallel by default and feeds the alignment
    /// step; turn this off in Settings to grade purely from the
    /// Quran-specialised model. Default ON for backward-compat.
    private var useDualEngine: Bool {
        (UserDefaults.standard.object(forKey: "useDualEngine") as? Bool) ?? true
    }


    /// Status message shown during model loading
    private(set) var loadingStatus: String = ""

    /// Estimated progress (0-1) for loading animation
    private(set) var loadingProgress: Double = 0

    // Playback support - keep audio in memory
    private(set) var lastRecordingData: Data?
    private(set) var lastRecordingDuration: Double = 0
    private(set) var lastWordTimestamps: [(word: String, start: Double, end: Double)] = []
    private var playbackPlayer: AVAudioPlayer?
    var isPlayingRecording = false
    var playbackProgress: Double = 0
    private var playbackTimer: Timer?

    // Track when recording started for trimming
    private(set) var recordingStartTime: Date?

    // MARK: - Model Loading

    func loadModel() async {
        dlog("[ayyat] loadModel() called - isLoaded=\(isModelLoaded), isLoading=\(isModelLoading), useFastConformer=\(useFastConformer)")
        guard !isModelLoaded, !isModelLoading else {
            dlog("[ayyat] loadModel() skipped - already loaded or loading")
            return
        }
        isModelLoading = true
        loadingProgress = 0.3
        state = .loading

        do {
            if useFastConformer {
                loadingStatus = "Loading FastConformer-Quran..."
                dlog("[ayyat] Loading FastConformer model...")
                let fc = try await FastConformerQuranASR(useANE: true)
                fastConformer = fc
                loadingStatus = "Optimized"
            } else {
                loadingStatus = "Loading Tarteel AI..."
                dlog("[ayyat] Loading Tarteel CPU model (fast)...")
                let w = try await TarteelWhisperKit()
                whisper = w
                loadingStatus = "Ready"
                // Upgrade Tarteel to ANE in background.
                Task.detached(priority: .background) {
                    await w.upgradeToANE()
                    await MainActor.run {
                        self.loadingStatus = w.isOptimized ? "Optimized" : "Ready"
                    }
                }
            }
            loadingProgress = 1.0
            isModelLoaded = true
            isModelLoading = false
            state = .idle
        } catch {
            dlog("[ayyat] Model loading failed: \(error)")
            loadingStatus = "Failed to load"
            state = .error("Model loading failed: \(error.localizedDescription)")
            isModelLoading = false
        }
    }

    func preloadModel() {
        guard !isModelLoaded, !isModelLoading else { return }
        isModelLoading = true
        loadingProgress = 0.1
        let useFC = useFastConformer
        loadingStatus = useFC ? "Loading FastConformer-Quran..." : "Loading Tarteel AI..."
        dlog("[ayyat] preloadModel() started — engine=\(useFC ? "FastConformer" : "Tarteel")")

        Task.detached(priority: .utility) { [weak self] in
            do {
                if useFC {
                    let fc = try await FastConformerQuranASR(useANE: true)
                    await MainActor.run {
                        guard let self, !self.isModelLoaded else { return }
                        self.fastConformer = fc
                        self.isModelLoaded = true
                        self.isModelLoading = false
                        self.loadingProgress = 1.0
                        self.loadingStatus = "Optimized"
                        self.state = .idle
                        dlog("[ayyat] FastConformer model ready")
                    }
                } else {
                    let w = try await TarteelWhisperKit()
                    await MainActor.run {
                        guard let self, !self.isModelLoaded else { return }
                        self.whisper = w
                        self.isModelLoaded = true
                        self.isModelLoading = false
                        self.loadingProgress = 1.0
                        self.loadingStatus = "Ready"
                        self.state = .idle
                        dlog("[ayyat] TarteelWhisperKit CPU model ready")
                    }
                    // Upgrade Tarteel to ANE in background.
                    Task.detached(priority: .background) {
                        await w.upgradeToANE()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isModelLoading = false
                    self?.loadingStatus = "Failed"
                    dlog("[ayyat] Model preload failed: \(error)")
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        dlog("[ayyat] startRecording() called")

        // Reentrancy guard. Block only while we're mid-transcription
        // (`.processing`) — kicking off a new recording on top of an
        // in-flight ASR would leak the prior recorder + cause result
        // crosstalk. We DO allow re-entering during `.recording`:
        // the visualizer is now tap-to-stop, so any re-tap goes through
        // that path instead of here.
        if state == .processing {
            dlog("[ayyat] startRecording() ignored — already processing prior recording")
            return
        }

        // Critical: only flip state to .recording AFTER permission is
        // confirmed and we're actually about to begin. The previous order
        // (state = .recording up front) caused the "double tap" bug —
        // first tap triggered the OS permission prompt, returned early,
        // but the UI already showed the recording state with no recorder
        // running. The user saw nothing happen and had to tap again.
        let permission = AVAudioApplication.shared.recordPermission
        dlog("[ayyat] Microphone permission: \(permission.rawValue)")
        switch permission {
        case .denied:
            dlog("[ayyat] Microphone access denied")
            state = .error("Microphone access denied")
            return
        case .undetermined:
            dlog("[ayyat] Requesting microphone permission...")
            // Pre-flight only — DON'T touch state. After grant we'll
            // re-enter startRecording() which will proceed past this guard
            // and only then set .recording.
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    dlog("[ayyat] Permission granted: \(granted)")
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.state = .error("Microphone required")
                    }
                }
            }
            return
        case .granted:
            dlog("[ayyat] Microphone permission granted")
        @unknown default:
            dlog("[ayyat] Unknown permission state")
        }

        // Permission confirmed — safe to claim the recording state.
        state = .recording

        // Strong-capture self in the detached Task so the checker can't
        // be deallocated mid-way through the audio-session dance — that
        // happened on the 2nd consecutive mic press: the [weak self] in
        // the inner MainActor.run was already nil by the time the audio
        // session settled (~50–200 ms later), and `self?.beginRecording()`
        // silently no-op'd. Result: "Starting recording..." logged, no
        // subsequent "Recording to:" line, no UI state change, recorder
        // never armed. Holding a strong reference keeps the instance
        // alive for the duration of the start-recording sequence.
        Task.detached { [self] in
            do {
                let session = AVAudioSession.sharedInstance()
                let prevCategory = session.category.rawValue
                let prevMode = session.mode.rawValue
                dlog("[ayyat] Setting audio session: \(prevCategory)/\(prevMode) -> record/measurement")
                try session.setCategory(.record, mode: .measurement)
                try session.setActive(true)
                dlog("[ayyat] Audio session configured for recording")
            } catch {
                dlog("[ayyat] Audio session error: \(error)")
                await MainActor.run {
                    self.state = .error("Microphone unavailable")
                }
                return
            }
            await MainActor.run {
                dlog("[ayyat] Starting recording...")
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        // If a stale recorder is hanging around from a previous (possibly
        // half-cancelled) attempt, release it before arming a new one.
        // Without this, AVAudioRecorder(url:settings:) below can throw
        // an "already prepared" error that we'd catch silently.
        if let stale = audioRecorder {
            stale.stop()
            audioRecorder = nil
            dlog("[ayyat] Released stale audioRecorder before new arm")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(UUID().uuidString).wav")
        recordingURL = url
        recordingStartTime = Date()
        dlog("[ayyat] Recording to: \(url.path)")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            let started = audioRecorder?.record() ?? false
            dlog("[ayyat] Recording started: \(started)")
        } catch {
            dlog("[ayyat] Recording error: \(error)")
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            state = .error("Recording failed")
        }
    }

    func stopRecording(expectedArabic: String, trimStartSeconds: Double = 0) async {
        dlog("[ayyat] stopRecording() called, trimStart: \(String(format: "%.2f", trimStartSeconds))s")
        audioRecorder?.stop()
        audioRecorder = nil  // Release recorder before changing session
        state = .processing

        // Deactivate recording session before switching to playback.
        // Restore to `.spokenAudio` (not `.default`) so the next Quran
        // playback gets correct routing — AudioPlaybackManager and
        // WordAudioPlayer both expect mode == .spokenAudio.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            dlog("[ayyat] Audio session switch error: \(error)")
        }

        guard let url = recordingURL else {
            dlog("[ayyat] No recording URL")
            state = .error("No recording")
            return
        }

        // Check recording file exists and duration
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        // 16kHz, 16-bit mono = 32000 bytes/sec (WAV header is 44 bytes)
        let duration = Double(max(0, fileSize - 44)) / 32000.0
        dlog("[ayyat] Recording: \(String(format: "%.1f", duration))s, trimming \(String(format: "%.1f", trimStartSeconds))s")

        let expected = expectedArabic

        let quranEngineName = fastConformer != nil ? "FastConformer" : (whisper != nil ? "Tarteel" : "none")
        let dualOn = useDualEngine
        dlog("[ayyat] Transcribing — engines: \(quranEngineName)\(dualOn ? "+AppleSpeech" : " only")")

        // Always run Apple Speech in parallel — even when the user has
        // turned off the explicit "dual engine" grading mode. Reason:
        // FastConformer occasionally returns empty on short utterances
        // where the user's speech started inside the CTC warm-up zone
        // (no leading silence). Apple Speech is more robust on those
        // and gives us a usable transcription instead of a dead result.
        // When `dualOn` is off we use Apple ONLY as fallback; when it's
        // on, Apple can also override FastConformer on disagreement.
        async let appleResult: AppleTranscriptionResult? = {
            do {
                return try await appleSpeech.transcribeWithTimestamps(url: url)
            } catch {
                dlog("[ayyat] Apple Speech failed: \(error)")
                return nil
            }
        }()

        // Route to whichever Quran-specialised ASR is loaded for this
        // session. Both expose `transcribeWithTimestamps(url:)` returning
        // the same `TranscriptionWithTimestamps` shape, so the alignment
        // path downstream stays untouched.
        let whisperModel = self.whisper
        let fcModel = self.fastConformer
        async let quranResult: TranscriptionWithTimestamps? = {
            if let fc = fcModel {
                do {
                    let result = try await fc.transcribeWithTimestamps(url: url)
                    dlog("[ayyat] FastConformer: '\(result.text)' (\(result.words.count) words, \(String(format: "%.2f", result.duration))s)")
                    return result
                } catch {
                    dlog("[ayyat] FastConformer failed: \(error)")
                    return nil
                }
            }
            if let w = whisperModel {
                do {
                    let result = try await w.transcribeWithTimestamps(url: url)
                    dlog("[ayyat] Tarteel: '\(result.text)' (\(result.words.count) words, \(String(format: "%.2f", result.duration))s)")
                    return result
                } catch {
                    dlog("[ayyat] Tarteel failed: \(error)")
                    return nil
                }
            }
            return nil
        }()

        let (apple, tarteel) = await (appleResult, quranResult)

        // Determine speech boundaries from ASR timestamps (more accurate than VAD)
        var speechStart: Double = 0
        var speechEnd: Double = duration

        if let apple = apple, !apple.segments.isEmpty {
            speechStart = apple.segments.first?.start ?? 0
            let lastSeg = apple.segments.last!
            speechEnd = lastSeg.start + lastSeg.duration
        } else if let tarteel = tarteel, !tarteel.words.isEmpty {
            speechStart = tarteel.words.first?.start ?? 0
            speechEnd = tarteel.words.last?.end ?? duration
        }

        // Add small buffer around speech (50ms before, 100ms after)
        speechStart = max(0, speechStart - 0.05)
        speechEnd = min(duration, speechEnd + 0.1)

        dlog("[ayyat] ASR speech bounds: \(String(format: "%.2f", speechStart))s - \(String(format: "%.2f", speechEnd))s")

        // Don't trim the audio — keep the full recording for playback.
        // Trimming was clipping speech that started right at sample 0
        // (no leading silence) and confusing the warm-up zone of CTC.
        // We still log the detected speech bounds for diagnostics.
        lastRecordingData = try? Data(contentsOf: url)
        lastRecordingDuration = duration

        // Clean up file now that we have data in memory
        try? FileManager.default.removeItem(at: url)

        // Save timestamps for playback highlighting. Use raw timestamps
        // (no `speechStart` subtraction) now that we keep the untrimmed
        // recording — timestamps already reference the full audio.
        if let apple = apple, !apple.segments.isEmpty {
            lastWordTimestamps = apple.segments.map {
                ($0.text, $0.start, $0.start + $0.duration)
            }
        } else if let tarteel = tarteel, !tarteel.words.isEmpty {
            lastWordTimestamps = tarteel.words.map {
                ($0.text, $0.start, $0.end)
            }
        } else {
            lastWordTimestamps = []
        }

        // Forced alignment check using timestamps from both engines
        let alignmentResult = checkForcedAlignment(
            expected: expected,
            appleResult: apple,
            tarteelResult: tarteel,
            audioDuration: duration
        )

        dlog("[ayyat] Alignment result: \(alignmentResult)")

        switch alignmentResult {
        case .match(let transcription):
            state = .result(correct: true, transcription: transcription)
        case .mismatch(let transcription):
            state = .result(correct: false, transcription: transcription)
        case .insertions(_):
            state = .result(correct: false, transcription: "Extra sounds detected")
        case .empty:
            // Both engines returned nothing — could be silent / very brief
            // input, a totally off-target utterance, or background noise.
            // Previously this dropped state back to `.idle` which left the
            // UI silent, making the user think the mic broke. Now surface
            // it as a "fail" with an explanation so feedback always fires.
            state = .result(correct: false, transcription: "Couldn't hear that. Try again")
        }
    }

    // MARK: - Playback

    func playRecording() {
        guard let data = lastRecordingData else { return }
        stopPlayback()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            playbackPlayer = try AVAudioPlayer(data: data)
            playbackPlayer?.play()
            isPlayingRecording = true
            playbackProgress = 0

            // Update progress during playback
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.playbackPlayer else { return }
                    if player.isPlaying {
                        self.playbackProgress = player.currentTime / max(player.duration, 0.1)
                    } else {
                        self.stopPlayback()
                    }
                }
            }
        } catch {
            dlog("[ayyat] Playback error: \(error)")
        }
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackPlayer?.stop()
        playbackPlayer = nil
        isPlayingRecording = false
        playbackProgress = 0
    }

    /// Get the currently highlighted word based on playback position
    func currentHighlightedWord() -> String? {
        guard isPlayingRecording, let player = playbackPlayer else { return nil }
        let currentTime = player.currentTime
        for (word, start, end) in lastWordTimestamps {
            if currentTime >= start && currentTime <= end {
                return word
            }
        }
        return nil
    }

    // MARK: - Forced Alignment

    private enum AlignmentResult: CustomStringConvertible {
        case match(String)
        case mismatch(String)
        case insertions(String)
        case empty

        var description: String {
            switch self {
            case .match(let t): return "match('\(t)')"
            case .mismatch(let t): return "mismatch('\(t)')"
            case .insertions(let t): return "insertions('\(t)')"
            case .empty: return "empty"
            }
        }
    }

    private func checkForcedAlignment(
        expected: String,
        appleResult: AppleTranscriptionResult?,
        tarteelResult: TranscriptionWithTimestamps?,
        audioDuration: Double
    ) -> AlignmentResult {
        let normalizedExpected = normalizeArabic(expected)
        let expectedWords = normalizedExpected.split(separator: " ").map(String.init)

        dlog("[Alignment] Expected: '\(normalizedExpected)' (\(expectedWords.count) words)")

        // Check Apple Speech (primary)
        if let apple = appleResult, !apple.segments.isEmpty {
            let appleWords = apple.segments.map { normalizeArabic($0.text) }.filter { !$0.isEmpty }
            dlog("[Alignment] Apple heard: '\(apple.text)' (\(appleWords.count) segments)")

            // Only flag insertions if significantly more words detected (3+ extra)
            // Single words can sometimes be split by ASR
            if appleWords.count > expectedWords.count + 2 {
                dlog("[Alignment] Apple: too many segments (\(appleWords.count) vs \(expectedWords.count) expected)")
                return .insertions(apple.text)
            }

            // Check if transcription matches expected
            if compareArabic(transcription: apple.text, expected: expected) {
                return .match(apple.text)
            }
        }

        // Check Tarteel (secondary - Quran-optimized)
        if let tarteel = tarteelResult, !tarteel.words.isEmpty {
            let tarteelWords = tarteel.words.map { normalizeArabic($0.text) }.filter { !$0.isEmpty }
            dlog("[Alignment] Tarteel heard: '\(tarteel.text)' (\(tarteelWords.count) words)")

            // Check if transcription matches expected
            if compareArabic(transcription: tarteel.text, expected: expected) {
                return .match(tarteel.text)
            }
        }

        // Fall back to text matching - prefer whichever matches
        if let apple = appleResult, !apple.text.isEmpty {
            if compareArabic(transcription: apple.text, expected: expected) {
                return .match(apple.text)
            }
            // Return what was heard so user knows
            return .mismatch(apple.text)
        }

        if let tarteel = tarteelResult, !tarteel.text.isEmpty {
            if compareArabic(transcription: tarteel.text, expected: expected) {
                return .match(tarteel.text)
            }
            return .mismatch(tarteel.text)
        }

        return .empty
    }

    func reset() {
        stopPlayback()
        lastRecordingData = nil
        lastRecordingDuration = 0
        lastWordTimestamps = []
        state = .idle
    }


    // MARK: - Arabic Comparison

    // Common ASR suffixes that don't change the root word
    private let commonSuffixes = ["ي", "ه", "ك", "ن", "ون", "ين", "ات", "ة", "ا"]

    /// Collapse Arabic characters into phonetic classes — Apple's
    /// general-purpose ASR maps Quranic consonants to nearby everyday
    /// ones (د↔ت, ث↔س, ذ↔ز, ظ↔ز, ص↔س, ض↔د, ط↔ت, ق↔ك, ر↔ل…) which makes
    /// strict character matching fail even when the user pronounced the
    /// word correctly. By rewriting each letter to a class representative,
    /// a correct pronunciation will match the expected word's phonetic
    /// shape regardless of which exact glyph the ASR wrote down.
    private func phoneticClass(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            // Dental / alveolar stops
            case "د", "ت", "ط", "ض": out.append("ت")
            // Sibilants
            case "س", "ث", "ص", "ز", "ذ", "ظ": out.append("س")
            case "ش":                            out.append("ش")  // its own class
            // Liquids
            case "ر", "ل":                       out.append("ل")
            // Velar / uvular stops
            case "ك", "ق":                       out.append("ك")
            // Pharyngeals / glottals — keep distinct from vowels
            case "ع", "غ":                       out.append("ع")
            case "ح", "خ", "ه":                  out.append("ه")
            // Long vowels — drop entirely (Apple inserts/drops these freely)
            case "ا", "و", "ي":                  continue
            // Everything else: keep as-is
            default: out.append(ch)
            }
        }
        return out
    }

    /// True when every character of `needle` appears in `haystack` in
    /// order (allowing other characters in between).
    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        outer: for c in needle {
            while let h = it.next() {
                if h == c { continue outer }
            }
            return false
        }
        return true
    }

    private func compareArabic(transcription: String, expected: String) -> Bool {
        let clean1 = normalizeArabic(transcription)
        let clean2 = normalizeArabic(expected)

        dlog("[Compare] normalized transcription='\(clean1)' expected='\(clean2)'")

        if clean1.isEmpty || clean2.isEmpty { return false }
        if clean1 == clean2 { return true }

        // Check if any word in transcription matches expected
        let transWords = clean1.split(separator: " ").map(String.init)
        let expWords = clean2.split(separator: " ").map(String.init)

        for word in transWords {
            // Direct match
            if word == clean2 || expWords.contains(word) {
                dlog("[Compare] Direct word match: '\(word)'")
                return true
            }

            // ASR might add common prefixes (و، ف، ب، ل) or suffixes
            // Only allow if the core word is the same
            for exp in expWords {
                // Word is expected + short suffix (1-2 chars)
                if word.hasPrefix(exp) && word.count <= exp.count + 2 {
                    dlog("[Compare] Suffix match: '\(word)' starts with '\(exp)'")
                    return true
                }
                // Expected is word + short suffix (ASR dropped it)
                if exp.hasPrefix(word) && exp.count <= word.count + 2 {
                    dlog("[Compare] ASR dropped suffix: '\(word)' vs '\(exp)'")
                    return true
                }
                // Common Arabic prefixes: و، ف، ب، ل، ال
                let prefixes = ["و", "ف", "ب", "ل", "ال", "لل"]
                for prefix in prefixes {
                    if word == prefix + exp || exp == prefix + word {
                        dlog("[Compare] Prefix match with '\(prefix)': '\(word)' <-> '\(exp)'")
                        return true
                    }
                }
            }
        }

        // Subsequence check — Apple Speech routinely inserts long-vowel
        // letters (alif after the first consonant) and trailing ya/taa
        // marbuta when transcribing short Quranic words. e.g. user says
        // 'bismi', Apple writes 'باسمي'. The user pronounced it
        // correctly, the ASR just spelled it long. If every consonant of
        // the expected word appears in the transcription in order, count
        // it as a match regardless of inserted vowels around them.
        for exp in expWords where exp.count >= 2 {
            for word in transWords where word.count >= exp.count {
                if isSubsequence(exp, of: word) {
                    dlog("[Compare] Subsequence match: '\(exp)' is contained in order in '\(word)'")
                    return true
                }
            }
        }

        // Consonant-skeleton overlap. Apple Speech often substitutes
        // common Arabic words it recognizes for rare Quranic words it
        // doesn't (e.g. user says أَيْفَكَ → Apple writes "إف كان"). The
        // user pronounced the right consonants — only the vowel script
        // differs. Drop the long vowels (ا, و, ي in pure-vowel role) and
        // compare what's left. If 80%+ of expected consonants appear in
        // the transcription, accept it.
        let vowels: Set<Character> = ["ا", "و", "ي", "ه"]
        let expConsonants = Array(clean2).filter { !vowels.contains($0) }
        let transConsonants = Array(clean1).filter { !vowels.contains($0) }
        if !expConsonants.isEmpty {
            var transBag: [Character: Int] = [:]
            for c in transConsonants { transBag[c, default: 0] += 1 }
            var matched = 0
            for c in expConsonants {
                if (transBag[c] ?? 0) > 0 {
                    transBag[c]! -= 1
                    matched += 1
                }
            }
            let consonantSim = Double(matched) / Double(expConsonants.count)
            dlog("[Compare] Consonant overlap: \(matched)/\(expConsonants.count) = \(consonantSim)")
            if consonantSim >= 0.80 {
                dlog("[Compare] Consonant-skeleton match")
                return true
            }
        }

        // Phonetic equivalence pass. Apple's general-purpose Arabic ASR
        // routinely confuses near-homophonic consonants (د vs ت, ر vs ل,
        // ث vs س, ذ vs ز, etc.) — the user says "duna" (دون), Apple
        // writes "tuna" (تونة). To accept that as a match, collapse
        // each character to a representative of its phonetic class and
        // re-compare.
        let phon1 = phoneticClass(clean1)
        let phon2 = phoneticClass(clean2)
        dlog("[Compare] Phonetic: trans='\(phon1)' exp='\(phon2)'")
        if phon1 == phon2 {
            dlog("[Compare] Phonetic-class match (exact)")
            return true
        }
        // Subsequence on phonetic-normalized strings.
        if phon2.count >= 2, isSubsequence(phon2, of: phon1) {
            dlog("[Compare] Phonetic subsequence match")
            return true
        }
        // Looser Levenshtein on phonetic forms — short words (≤4 chars)
        // tolerate one substitution, longer words tolerate 1-2.
        let phonDist = levenshtein(phon1, phon2)
        let phonMaxLen = max(phon1.count, phon2.count, 1)
        let phonSim = 1.0 - Double(phonDist) / Double(phonMaxLen)
        let phonThreshold: Double = phon2.count <= 4 ? 0.65 : 0.75
        dlog("[Compare] Phonetic similarity \(phonSim) vs threshold \(phonThreshold)")
        if phonSim >= phonThreshold {
            dlog("[Compare] Phonetic Levenshtein match")
            return true
        }

        // Levenshtein distance - strict matching after normalization
        let dist = levenshtein(clean1, clean2)
        let maxLen = max(clean1.count, clean2.count, 1)
        let similarity = 1.0 - Double(dist) / Double(maxLen)

        dlog("[Compare] Levenshtein dist=\(dist) similarity=\(similarity)")

        // Strict thresholds - this is pronunciation practice
        // After normalization (diacritics removed, alefs unified), should be very close
        let threshold: Double
        if clean2.count <= 2 {
            threshold = 1.0  // 1-2 chars: must be exact
        } else if clean2.count <= 3 {
            threshold = 0.85  // 3 chars: allow 1 char diff max
        } else {
            threshold = 0.80  // 4+ chars: 80% match (1-2 char diff allowed)
        }

        return similarity >= threshold
    }

    private func normalizeArabic(_ text: String) -> String {
        var result = String(text.unicodeScalars.filter { s in
            // Arabic diacritics (tashkeel)
            if s.value >= 0x064B && s.value <= 0x065F { return false }
            // Quranic annotation marks
            if s.value >= 0x0610 && s.value <= 0x061A { return false }
            if s.value >= 0x06D6 && s.value <= 0x06ED { return false }
            // Tatweel (kashida) and superscript alef
            if s.value == 0x0640 || s.value == 0x0670 { return false }
            // RTL/LTR marks and zero-width characters
            if s.value == 0x200F || s.value == 0x200E { return false }  // RTL/LTR marks
            if s.value >= 0x200B && s.value <= 0x200D { return false }  // Zero-width spaces
            if s.value == 0x00AD { return false }  // Soft hyphen
            if s.value == 0xFEFF { return false }  // BOM
            return true
        })

        // Normalize alef variants to plain alef
        result = result.replacingOccurrences(of: "أ", with: "ا")
        result = result.replacingOccurrences(of: "إ", with: "ا")
        result = result.replacingOccurrences(of: "آ", with: "ا")
        result = result.replacingOccurrences(of: "ٱ", with: "ا")
        // Normalize teh marbuta to heh
        result = result.replacingOccurrences(of: "ة", with: "ه")
        // Normalize alef maqsura to yeh
        result = result.replacingOccurrences(of: "ى", with: "ي")
        // Hamza on ya / waw → strip the hamza, keep the base letter.
        // Apple Speech and FastConformer both vary in whether they emit
        // the hamza form vs the plain form for the same sound.
        result = result.replacingOccurrences(of: "ئ", with: "ي")
        result = result.replacingOccurrences(of: "ؤ", with: "و")
        // Standalone hamza — collapse out, no consistent phonetic effect
        // in user speech.
        result = result.replacingOccurrences(of: "ء", with: "")
        // Collapse whitespace — Apple Speech routinely splits a single
        // Arabic word into two segments ("إف كان" for one utterance of
        // "afkan"). Without this, the space-vs-no-space mismatch
        // inflates Levenshtein distance against the expected single-
        // word target.
        result = result.replacingOccurrences(of: " ", with: "")
        result = result.replacingOccurrences(of: "\u{00A0}", with: "")    // non-breaking space

        // Collapse adjacent identical letters AFTER diacritics are stripped.
        // Quranic text uses shadda (already removed above) to indicate
        // geminated consonants, so two unshaddaed copies of the same
        // letter in a row in raw script are virtually always CTC
        // over-emission — `الذيين` → `الذين`, `لذينهه` → `لذينه`.
        var collapsed = ""
        var last: Character? = nil
        for ch in result {
            if ch == last { continue }
            collapsed.append(ch)
            last = ch
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1))
            }
        }
        return d[a.count][b.count]
    }
}

// MARK: - Shared Instance

/// Access only from @MainActor contexts (enforced by PronunciationChecker).
enum SharedPronunciationChecker {
    @MainActor static let checker = PronunciationChecker()
}


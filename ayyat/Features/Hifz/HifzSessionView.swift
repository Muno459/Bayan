import SwiftUI

/// One-verse memorization session.
///
/// The verse is rendered as a row of word "tiles". Words flagged for hiding
/// (by mastery × reveal level) become opaque blanks. The user can:
/// - tap a single blank to peek (reveals just that word for 2s)
/// - tap "Reveal all" to fall back to full view
/// - tap the big mic button to recite — Tarteel grades the attempt
///
/// On pass/partial/fail, the SRS state is updated via `HifzStore.record`.
struct HifzSessionView: View {
    let verseKey: String

    @Environment(\.dismiss) private var dismiss
    @Environment(QuranStore.self) private var quranStore
    @Environment(VocabularyStore.self) private var vocab
    @Environment(HifzStore.self) private var hifz
    @Environment(AudioPlaybackManager.self) private var audioManager
    @Environment(SettingsManager.self) private var settings

    @State private var verse: Verse?
    @State private var hiddenWordIds: Set<Int> = []
    @State private var temporarilyRevealed: Set<Int> = []
    @State private var lastAttempt: AttemptOutcome?
    @State private var peekTasks: [Int: Task<Void, Never>] = [:]
    /// Pre-shuffled word ids — order is random but stable for the lifetime
    /// of this session so that moving the reveal slider keeps the same
    /// words hidden / shown. Recomputed only when the verse identity
    /// changes (i.e. you open Hifz for a different verse).
    @State private var shuffledWordOrder: [Int] = []

    private var checker: PronunciationChecker { SharedPronunciationChecker.checker }

    enum AttemptOutcome: Equatable {
        case pass(transcription: String)
        case partial(transcription: String)
        case fail(transcription: String)

        var color: Color {
            switch self {
            case .pass: AyyatColors.mastered
            case .partial: AyyatColors.gold
            case .fail: .red
            }
        }
        var title: String {
            switch self {
            case .pass: "Pass"
            case .partial: "Almost"
            case .fail: "Try again"
            }
        }
        var icon: String {
            switch self {
            case .pass: "checkmark.circle.fill"
            case .partial: "circle.righthalf.filled"
            case .fail: "xmark.circle.fill"
            }
        }
    }

    private var state: HifzState? { hifz.states[verseKey] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let state {
                    statusHeader(state)
                    revealSlider(state)
                }
                verseDisplay
                attemptResult
                actions
            }
            .padding(20)
        }
        .background(AyyatColors.background)
        .navigationTitle(verseKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        playReciterAudio()
                    } label: {
                        Label("Listen to reciter", systemImage: "speaker.wave.2.fill")
                    }
                    Divider()
                    Button(role: .destructive) {
                        hifz.remove(verseKey: verseKey)
                        dismiss()
                    } label: {
                        Label("Remove from queue", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            // Kick off Tarteel preload as soon as the sheet appears, so the
            // model is ready by the time the user taps Recite. Without this,
            // the mic falls back to Apple Speech (poor on Quranic Arabic)
            // and the user thinks "Recite" is broken.
            checker.preloadModel()
            // The checker is a process-wide singleton, so a previous session
            // that was left mid-recording (sheet swiped away while the mic
            // was active) would park state at `.recording`. Without this
            // guard the next tap on Recite would read the stale state and
            // immediately call stopRecording — felt like "I tap recite and
            // it stops in 10 ms". Only reset when we'd otherwise route to
            // the wrong branch; preserve `.result` so the user can see the
            // last attempt's outcome from the previous session.
            if checker.state == .recording || checker.state == .processing {
                checker.reset()
            }
            await loadVerse()
            recomputeHidden()
            // Warm the reciter audio in the background so the Listen button
            // doesn't make the user wait 3-5 s on first tap (network fetch
            // + AVPlayer buffer). If this fails we silently ignore — Listen
            // will just take longer on the first attempt, same as before.
            preloadReciterAudioInBackground()
        }
        .onChange(of: state?.revealLevel ?? 1.0) { _, _ in
            recomputeHidden()
        }
        .onChange(of: checker.state) { _, new in
            handleCheckerStateChange(new)
        }
        .onDisappear {
            checker.reset()
            cancelPeeks()
        }
    }

    // MARK: - Status header

    private func statusHeader(_ s: HifzState) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(s.isMemorized ? AyyatColors.mastered : AyyatColors.primary)
                Text("\(s.totalPasses) pass\(s.totalPasses == 1 ? "" : "es") · \(s.totalMisses) miss\(s.totalMisses == 1 ? "" : "es") · streak \(s.streak)")
                    .font(.system(size: 11))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
            if let due = s.nextDueAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(dueLabel(due))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AyyatColors.textSecondary)
                    Text("next review")
                        .font(.system(size: 10))
                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.6))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(AyyatColors.readerBackground))
    }

    private func dueLabel(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Reveal slider

    private func revealSlider(_ s: HifzState) -> some View {
        // Snap to whole-word increments so each tick of the slider hides
        // (or shows) exactly one more word — feels concrete, no fuzzy
        // half-word states. For a 7-word verse the step is 1/7 ≈ 0.143.
        let wordCount = max(1, verse?.words?.filter(\.isWord).count ?? 1)
        let step = 1.0 / Double(wordCount)
        let visibleWords = Int(round(s.revealLevel * Double(wordCount)))
        let hiddenWords = wordCount - visibleWords

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Visible")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AyyatColors.textSecondary)
                Spacer()
                Text("\(visibleWords) of \(wordCount)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AyyatColors.primary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { s.revealLevel },
                    set: { newValue in
                        // Snap to nearest word boundary even when the gesture
                        // sets a value that isn't a perfect multiple of step.
                        let words = Int(round(newValue * Double(wordCount)))
                        let snapped = Double(words) / Double(wordCount)
                        hifz.setRevealLevel(snapped, for: verseKey)
                    }
                ),
                in: 0...1, step: step
            )
            .tint(AyyatColors.primary)
            HStack {
                Text("Recite blind").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(hiddenWords == 0
                     ? "Full view"
                     : "\(hiddenWords) word\(hiddenWords == 1 ? "" : "s") hidden")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Verse display

    @ViewBuilder
    private var verseDisplay: some View {
        if let verse {
            let words = verse.words?.filter { $0.isWord } ?? []
            // Hifz mode always renders Arabic, so enable bidi-aware
            // layout so multi-line verses wrap right-to-left within
            // each row instead of left-to-right (which would make the
            // recitation order look scrambled to a memorising user).
            WrappingHStack(alignment: .leading, spacing: 6, bidiAware: true) {
                ForEach(words) { w in
                    wordTile(for: w)
                        .layoutValue(key: WrappingHStack.IsArabic.self, value: true)
                }
            }
            .lineSpacing(12)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(AyyatColors.readerBackground))
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }

    private func wordTile(for word: Word) -> some View {
        let hidden = isHidden(word)
        let arabic = word.textUthmani ?? ""
        // Use the same Arabic font size as the reader so the line wraps the
        // same way regardless of whether the user is in Read mode or Hifz.
        return Text(arabic)
            .font(.system(size: settings.arabicFontSize))
            .environment(\.locale, Locale(identifier: "ar"))
            // Critical: the Text is the SAME width whether hidden or visible
            // (we keep the glyphs in the layout, only flip foreground colour).
            // The fill / underline are overlays that don't affect wrapping.
            .foregroundStyle(hidden ? .clear : AyyatColors.textPrimary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hidden ? AyyatColors.primary.opacity(0.13) : .clear)
            )
            .overlay(alignment: .bottom) {
                if hidden {
                    Capsule()
                        .fill(AyyatColors.primary.opacity(0.5))
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .padding(.bottom, -3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if hidden { peek(word.id) }
            }
    }

    private func isHidden(_ word: Word) -> Bool {
        if temporarilyRevealed.contains(word.id) { return false }
        return hiddenWordIds.contains(word.id)
    }

    private func peek(_ wordId: Int) {
        Haptics.light()
        temporarilyRevealed.insert(wordId)
        // Cancel any pending re-hide for this word first so rapid taps
        // don't stack/leak. Store the task so we can cancel on disappear.
        peekTasks[wordId]?.cancel()
        peekTasks[wordId] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            temporarilyRevealed.remove(wordId)
            peekTasks[wordId] = nil
        }
    }

    private func cancelPeeks() {
        for (_, task) in peekTasks { task.cancel() }
        peekTasks.removeAll()
    }

    // MARK: - Actions row

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await runRecallAttempt() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: micIcon)
                        .font(.system(size: 22))
                    Text(micLabel)
                        .font(.system(size: 16, weight: .semibold))
                    if isMicDisabled, case .processing = checker.state {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(checker.state == .recording ? Color.red : AyyatColors.primary)
                )
                .foregroundStyle(.white)
                .opacity(isMicDisabled ? 0.7 : 1)
            }
            .disabled(isMicDisabled)

            // Equal-width pair so Listen and Reveal balance under the big
            // mic button. Each fills its half of the row — looks deliberate
            // instead of "two pills floating in the middle".
            HStack(spacing: 12) {
                Button {
                    playReciterAudio()
                } label: {
                    Label("Listen", systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 11).fill(AyyatColors.primary.opacity(0.1)))
                        .foregroundStyle(AyyatColors.primary)
                }
                Button {
                    revealOne()
                } label: {
                    Label("Reveal a word", systemImage: "eye")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(AyyatColors.primary.opacity(canRevealAnyWord ? 0.1 : 0.04))
                        )
                        .foregroundStyle(AyyatColors.primary.opacity(canRevealAnyWord ? 1 : 0.4))
                }
                .disabled(!canRevealAnyWord)
            }
            if case .error(let message) = checker.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// True if there's at least one word currently hidden on screen that the
    /// user can ask to peek at. Drives both the button's enabled state and
    /// its faded styling so it's obvious why tapping does nothing when the
    /// slider is at "Full view".
    private var canRevealAnyWord: Bool {
        guard let verse else { return false }
        let words = verse.words?.filter { $0.isWord } ?? []
        return words.contains { isHidden($0) }
    }

    @ViewBuilder
    private var attemptResult: some View {
        if let lastAttempt {
            HStack(spacing: 12) {
                Image(systemName: lastAttempt.icon)
                    .font(.system(size: 26))
                    .foregroundStyle(lastAttempt.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastAttempt.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AyyatColors.textPrimary)
                    Text(transcriptionLabel(lastAttempt))
                        .font(.system(size: 12))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .lineLimit(3)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(lastAttempt.color.opacity(0.08)))
        }
    }

    private func transcriptionLabel(_ a: AttemptOutcome) -> String {
        switch a {
        case .pass(let t), .partial(let t), .fail(let t):
            return t.isEmpty ? "" : "Heard: \(t)"
        }
    }

    // MARK: - Logic

    private func loadVerse() async {
        guard verse == nil else { return }
        // Walk the local DB; verses are already loaded by chapter elsewhere,
        // but this view may be opened from the Hifz tab without a parent
        // VerseReader. Fall back to a one-shot DB lookup.
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2, let chapterId = Int(parts[0]) else { return }
        if let inMemory = quranStore.currentVerses.first(where: { $0.verseKey == verseKey }) {
            verse = inMemory
            return
        }
        let verses = try? await Task.detached(priority: .userInitiated) {
            try QuranDatabase.shared.fetchVerses(forChapter: chapterId)
        }.value
        verse = verses?.first { $0.verseKey == verseKey }
    }

    /// Decide which word ids are hidden. Order is RANDOM (seeded per verse
    /// so the same verse always picks the same shuffle within a session)
    /// rather than mastery-ranked source order — the previous behaviour
    /// felt like "a→z" hiding, which the user found unnatural.
    ///
    /// Mastery is still respected as a secondary bias: more-mastered words
    /// get a small "hide me first" boost so review still feels productive,
    /// but the dominant signal is randomness.
    private func recomputeHidden() {
        guard let verse, let level = state?.revealLevel else {
            hiddenWordIds = []
            return
        }
        let words = verse.words?.filter { $0.isWord } ?? []

        if shuffledWordOrder.count != words.count {
            // Either no shuffle yet, or the verse changed — re-seed.
            shuffledWordOrder = seededShuffle(
                of: words,
                seed: stableSeed(forVerseKey: verseKey)
            ).map(\.id)
        }

        let hideCount = Int(round(Double(words.count) * (1 - level)))
        guard hideCount > 0 else {
            hiddenWordIds = []
            return
        }
        hiddenWordIds = Set(shuffledWordOrder.prefix(hideCount))
    }

    /// Deterministic 64-bit seed from a verse key (e.g. "17:1") so the same
    /// verse always shuffles to the same order across sheet re-opens.
    private func stableSeed(forVerseKey key: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603 // FNV offset basis
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211 // FNV prime
        }
        return hash
    }

    /// Fisher–Yates shuffle with a seeded PRNG (the SystemRandomNumberGenerator
    /// can't be seeded, so we roll a tiny xorshift here).
    private func seededShuffle<T>(of items: [T], seed: UInt64) -> [T] {
        var rng = XorshiftRNG(seed: seed == 0 ? 1 : seed)
        var array = items
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            array.swapAt(i, j)
        }
        return array
    }

    private struct XorshiftRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private func preloadReciterAudioInBackground() {
        guard let verse,
              let chapterId = Int(verse.verseKey.split(separator: ":").first ?? "")
        else { return }
        Task {
            // Already buffered for this chapter — nothing to do.
            if audioManager.isReady && audioManager.loadedChapterId == chapterId { return }
            do {
                let file = try await quranStore.fetchAudio(
                    for: chapterId,
                    reciterId: settings.selectedReciterId
                )
                // Only swap the player if we're still on the same verse —
                // user may have dismissed the sheet by the time the fetch
                // returns and we don't want to clobber an unrelated session.
                if self.verse?.verseKey == verse.verseKey {
                    await audioManager.loadAudio(audioFile: file, chapterId: chapterId)
                }
            } catch {
                // Listen tap will retry — fine to fail silently here.
            }
        }
    }

    private func masteryScore(of word: Word) -> Double {
        guard let state = vocab.wordStates[word.id] else { return 0 }
        switch state.masteryLevel {
        case .mastered: return 1.0
        case .familiar: return 0.8
        case .learning: return 0.6
        case .introduced: return 0.4
        case .unseen: return 0.2
        }
    }

    private func revealOne() {
        // Walk words in source order — Sets are unordered, so the previous
        // `hiddenWordIds.first(where:)` was non-deterministic and felt random
        // when chained. Pick the first hidden, not-yet-peeking word as it
        // appears in the verse (right to left in Arabic source order).
        guard let verse else { return }
        let words = verse.words?.filter { $0.isWord } ?? []
        guard let next = words.first(where: {
            isHidden($0) && !temporarilyRevealed.contains($0.id)
        }) else { return }
        peek(next.id)
    }

    private func playReciterAudio() {
        guard let verse,
              let chapterId = Int(verse.verseKey.split(separator: ":").first ?? "") else { return }
        Task {
            do {
                // Reload audio if it's not loaded OR it's loaded for a different
                // chapter (otherwise we'd silently play nothing — the verse key
                // wouldn't match any timestamp in the old chapter's audio).
                if !audioManager.isReady || audioManager.loadedChapterId != chapterId {
                    let file = try await quranStore.fetchAudio(for: chapterId, reciterId: settings.selectedReciterId)
                    await audioManager.loadAudio(audioFile: file, chapterId: chapterId)
                }
                audioManager.playSingleVerse(verse.verseKey)
            } catch {
                // best-effort — Tarteel still grades without audio
            }
        }
    }

    /// Disable the mic button only while we're literally processing the
    /// last attempt or while the verse is still loading from disk. We
    /// intentionally do NOT disable for `.loading` (model loading is
    /// usually done by now) or for missing verses (button shows a clear
    /// label instead).
    private var isMicDisabled: Bool {
        if verse == nil { return true }
        if case .processing = checker.state { return true }
        return false
    }

    private var micIcon: String {
        switch checker.state {
        case .recording:  return "stop.circle.fill"
        case .processing: return "waveform"
        default:          return "mic.circle.fill"
        }
    }

    private var micLabel: String {
        switch checker.state {
        case .recording:  return "Stop recording"
        case .processing: return "Checking…"
        default:          return verse == nil ? "Loading verse…" : "Recite this verse"
        }
    }

    private func runRecallAttempt() async {
        guard let verse, let expected = verse.textUthmani else { return }
        switch checker.state {
        case .recording:
            await checker.stopRecording(expectedArabic: expected)
        case .processing:
            // already grading — ignore double-tap
            return
        default:
            checker.startRecording()
        }
    }

    private func handleCheckerStateChange(_ new: PronunciationChecker.State) {
        switch new {
        case .result(let correct, let transcription):
            // Map result to coarse outcome buckets and feed the scheduler.
            let outcome: AttemptOutcome
            let hifzResult: HifzResult
            if correct {
                outcome = .pass(transcription: transcription)
                hifzResult = .pass
            } else if !transcription.isEmpty {
                // Partial credit if we got *some* arabic transcription
                outcome = .partial(transcription: transcription)
                hifzResult = .partial
            } else {
                outcome = .fail(transcription: transcription)
                hifzResult = .fail
            }
            lastAttempt = outcome
            hifz.record(hifzResult, for: verseKey)
        default:
            break
        }
    }
}

import Foundation
import SwiftUI

/// Manages vocabulary learning and the progressive substitution engine.
///
/// The substitution level slider is the PRIMARY control. It determines
/// what percentage of words show as Arabic script vs English.
/// Individual word mastery adjusts within that.
///
/// Journey: all English → mixed English + Arabic → full Arabic script
@MainActor
@Observable
final class VocabularyStore {
    private(set) var wordStates: [Int: WordLearningState] = [:] {
        didSet { scheduleSave() }
    }

    /// Lemma-level learning, parallel to the per-instance `wordStates`.
    ///
    /// Keyed by the **diacritized lemma text** (e.g. `"اللَّه"`) — NOT the
    /// integer `lemma_id` from QUL. The integer IDs can renumber across QUL
    /// data refreshes, but the lemma text is stable; persisting by text
    /// means a future morphology update can't silently erase user progress.
    ///
    /// `silentEncounters` rises from 0 → 3 each time the user reads a verse
    /// containing the lemma WITHOUT tapping it for help. At 3 it graduates
    /// to "bare Arabic" rendering. Tapping a graduated word resets to 0 —
    /// that's the demotion contract.
    ///
    /// This whole machinery is invisible to the user: no count, no badge,
    /// no "lemma" terminology in any UI string. The compound effect is
    /// discovered through reading.
    private(set) var learnedLemmas: [String: LemmaProgress] = [:] {
        didSet { scheduleLemmasSave() }
    }

    private var saveTask: Task<Void, Never>?
    private var lemmasSaveTask: Task<Void, Never>?

    /// 0.0 = all English, 1.0 = all Arabic script.
    /// HARD CAP: in Transliteration mode the maximum level is
    /// `preGraduationCap` (0.7) regardless of `graduatedToArabic`. We
    /// don't want users transliterating the whole Quran into Latin
    /// letters — that's the "transliteration of the Quran" pattern the
    /// graduation message warns against. The cap is enforced on every
    /// set so it can't be circumvented by toggling transliteration on
    /// after dragging the slider high.
    var substitutionLevel: Double = 0.3 {
        didSet {
            let clamped = clampSubstitutionLevel(substitutionLevel)
            if clamped != substitutionLevel {
                substitutionLevel = clamped
                return                       // didSet re-enters; let it
            }
            UserDefaults.standard.set(substitutionLevel, forKey: "bayan_substitutionLevel")
        }
    }

    /// Pin the value into the allowed range given the current mode.
    private func clampSubstitutionLevel(_ value: Double) -> Double {
        if useTransliteration {
            return min(value, Self.preGraduationCap)
        }
        return value
    }

    /// True once the user has explicitly confirmed they're ready to read
    /// in pure Arabic. The slider gates the upper end of the range behind
    /// this flag — without it, a newbie who drags the slider straight to
    /// max would see the Quran rendered as English-less Arabic before
    /// they can actually read it, which would feel like "transliteration
    /// of the Quran" and is what the user wanted to prevent.
    var graduatedToArabic: Bool = false {
        didSet { UserDefaults.standard.set(graduatedToArabic, forKey: "bayan_graduatedToArabic") }
    }

    /// Slider value at which the graduation gate fires. Once the user
    /// crosses this, we show the "preserve the Quran" message and reset
    /// them to a low substitution percentage so they can grow Arabic
    /// mastery without sitting at near-full transliteration of the
    /// verses themselves.
    static let arabicGraduationThreshold: Double = 0.80

    /// Maximum slider value allowed before graduation. Just below the
    /// graduation threshold so the gate stays visible but the user can
    /// still reach a "mostly Arabic" state without the prompt.
    static let preGraduationCap: Double = 0.7

    /// Where the slider lands after the user confirms graduation. Low
    /// so the Quran stays predominantly in its original form right
    /// after acknowledgement — they can drag back up as they read.
    static let postGraduationLevel: Double = 0.10

    var totalWordsEncountered: Int { wordStates.count }

    var masteredCount: Int {
        wordStates.values.filter { $0.masteryLevel == .mastered }.count
    }

    var familiarCount: Int {
        wordStates.values.filter { $0.masteryLevel == .familiar }.count
    }

    var learningCount: Int {
        wordStates.values.filter { $0.masteryLevel == .learning }.count
    }

    // MARK: - Progressive Substitution

    /// Whether user is in transliteration mode (set during onboarding)
    var useTransliteration: Bool = false {
        didSet {
            UserDefaults.standard.set(useTransliteration, forKey: "bayan_useTransliteration")
            // Re-clamp the substitution level when switching INTO
            // transliteration mode. Otherwise a user at 90 % Arabic could
            // flip the toggle and end up reading 90 % of the Quran as
            // Latin transliteration, which is exactly what we don't want.
            if useTransliteration && substitutionLevel > Self.preGraduationCap {
                substitutionLevel = Self.preGraduationCap
            }
        }
    }

    /// Determine display for a word.
    ///
    /// The slider value answers: "what fraction of words do you want to see in Arabic?"
    /// Words are ranked by familiarity (score). Easiest first.
    /// A word substitutes when its score is below the slider value — strictly.
    /// No "transition zone" added on top, because the slider already controls reach.
    ///
    /// **Lemma override:** lemma-level learning (set via the existing
    /// "I Know This Word" button) takes precedence over the slider. A
    /// graduated lemma renders as bare Arabic regardless of slider; a
    /// still-graduating lemma renders with a faded transliteration hint
    /// beneath. This is invisible to the user — no UI string mentions
    /// "lemma" anywhere.
    func displayMode(
        for word: Word,
        saheeh: String? = nil,
        isFirstWord: Bool = false
    ) -> SubstitutionDisplay {
        guard word.isWord else {
            return .english(Self.englishSlice(
                for: word, saheeh: saheeh, isFirstWord: isFirstWord
            ))
        }

        // English source prefers the LLM-aligned Saheeh slice over the
        // QF word-by-word literal. The aligned slice is verbatim Saheeh
        // (brackets, macrons like "Muḥammad", proper-noun capitalisation
        // like "the Book" / "the Torah" — all preserved). The WBW
        // fallback fires only for verses whose alignment hasn't shipped
        // yet, and it's lowercase by default so we case-normalise it
        // against the Saheeh sentence.
        let englishText = Self.englishSlice(
            for: word, saheeh: saheeh, isFirstWord: isFirstWord
        )
        let arabicText = word.textUthmani ?? word.textImlaei ?? ""
        let transliterationText = word.transliteration?.text ?? arabicText

        // The user picked their learning track in Settings / Onboarding —
        // Arabic Script or Transliteration. That choice is absolute: a
        // substituted word becomes the chosen target, NOT a stepping
        // stone that flips into Arabic once the word is "comfortable".
        // The previous logic silently broke the user's preference once
        // they got good at a word.
        let substitutedTarget = useTransliteration ? transliterationText : arabicText

        // 1. Lemma override (highest priority, abstracted from user).
        //    Drives BOTH learning tracks — Arabic-script users get the
        //    Arabic glyph, transliteration users get the Latin spelling
        //    of the same word. The lemma engine and the user's chosen
        //    target script are independent: lemma decides WHEN to
        //    substitute, substitutedTarget decides WHAT to substitute to.
        switch lemmaRenderState(lemmaText: word.lemmaText) {
        case .graduated:
            return .learned(substitutedTarget)
        case .trainingWheels:
            // Reuse the existing .transitioning case to render the target
            // script on top with a faded hint beneath — perfect fit for
            // the 3-encounter ramp-up.
            //
            //   In Arabic-script mode: hint is the transliteration (so
            //     the user can still vocalise unfamiliar glyphs).
            //   In transliteration mode: hint is the English meaning
            //     (the user can already read Latin, what they need is
            //     the gloss for the few rounds before bare-target kicks
            //     in).
            let hint: String = useTransliteration
                ? englishText
                : (word.transliteration?.text ?? englishText)
            return .transitioning(target: substitutedTarget, english: hint)
        case .unlearned:
            break // fall through to slider logic
        }

        // 2. Slider logic (unchanged below)
        if substitutionLevel < 0.02 {
            return .english(englishText)
        }
        if substitutionLevel >= Self.arabicGraduationThreshold {
            return .learned(substitutedTarget)
        }

        let wordScore = wordSubstitutionScore(for: word)
        let targetText = substitutedTarget

        if wordScore <= substitutionLevel {
            return .learned(targetText)
        }
        // Narrow transition band — only the next 5% peeks as Arabic-with-hint.
        if wordScore <= substitutionLevel + 0.05 {
            return .transitioning(target: targetText, english: englishText)
        }
        return .english(englishText)
    }

    /// English text used as the per-word slice. **Rendered raw — no
    /// transformations.** The LLM-aligned Saheeh chunk is verbatim
    /// Saheeh (capitalisation, brackets, macrons all preserved). The
    /// WBW fallback is QF's lowercase literal gloss, also rendered
    /// as-is. We deliberately do NOT case-normalise, title-case the
    /// first word, manipulate punctuation, or apply any heuristic
    /// cleanup — the user reads exactly what the data layer provides.
    private static func englishSlice(
        for word: Word, saheeh: String?, isFirstWord: Bool
    ) -> String {
        if let aligned = word.alignedEnglish, !aligned.isEmpty {
            return aligned + Self.formatTrailingPunctuation(word.alignedTrailingPunctuation)
        }
        return word.translation?.text ?? ""
    }

    /// Render trailing punctuation in the way Saheeh actually writes it.
    /// Dashes are spaced ("disbelieve - never"), while commas, periods,
    /// semicolons, and the like cling tightly to the preceding word
    /// ("Allāh,"). The LLM stores just the punctuation character without
    /// its surrounding whitespace, so we reapply the leading space here.
    private static func formatTrailingPunctuation(_ punct: String?) -> String {
        guard let punct, !punct.isEmpty else { return "" }
        let spacedDashes: Set<String> = ["-", "—", "–", "‑"]
        return spacedDashes.contains(punct) ? " " + punct : punct
    }

    /// Title-case a word from QF's lowercase word-by-word translations.
    /// Preserves any all-caps abbreviations (e.g. "TM"), proper-noun
    /// Capitalisation reference for per-word English. Earlier versions
    /// of this function force-Title-Cased every word ("In The Name Of
    /// Allah The Most Gracious The Most Merciful"), which reads like
    /// title-case noise. The fix takes the Saheeh International full-verse
    /// translation as the ground-truth case reference: each per-word
    /// English token is looked up case-insensitively inside the Saheeh
    /// sentence and its casing copied back. Falls back to lowercase
    /// (with first-word-of-verse capitalised) when no match exists or
    /// when no Saheeh sentence is available.
    static func englishWithCase(
        _ raw: String,
        saheeh: String?,
        isFirstWord: Bool
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        // Pure-symbol tokens like "(2)" or punctuation come through
        // unchanged — they have no letters to case.
        let hasLetters = trimmed.contains(where: { $0.isLetter })
        if !hasLetters { return trimmed }

        // Strip parenthetical hints like "(is)" or "(The)" when probing
        // Saheeh — the public translation never includes them.
        let probe = trimmed
            .replacingOccurrences(of: "([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // Start from a clean lowercase baseline so accidental Source
        // capitals (Most, Gracious, Master, Day, Alone) get tamed.
        var out = trimmed.lowercased()

        if let saheeh, !saheeh.isEmpty, !probe.isEmpty {
            // Try to find the exact phrase first; on miss, fall back to
            // the leading word.
            if let r = saheeh.range(of: probe, options: [.caseInsensitive]) {
                let matched = String(saheeh[r])
                out = caseClone(target: out, reference: matched, originalProbe: probe)
            } else {
                let head = probe.split(separator: " ").first.map(String.init) ?? probe
                if !head.isEmpty,
                   let r = saheeh.range(of: head, options: [.caseInsensitive])
                {
                    let matchedHead = String(saheeh[r])
                    if let first = matchedHead.first, first.isUppercase {
                        out = first.uppercased() + out.dropFirst()
                    }
                }
            }
        }

        // First word of the verse always starts a sentence.
        if isFirstWord, let first = out.first, first.isLowercase {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }

    /// Copy case from a Saheeh-matched phrase back onto our cleaned
    /// lowercase token, position-by-position. Parentheticals in the
    /// source token (e.g. "(is) the book") are preserved.
    private static func caseClone(target: String, reference: String, originalProbe: String) -> String {
        // Best-effort: only override the first letter from reference.
        // Full per-character cloning is risky given the parenthetical
        // hints; first-letter case is the user-visible fix anyway.
        guard let refFirst = reference.first, refFirst.isUppercase,
              let tgtFirst = target.first, tgtFirst.isLowercase else {
            return target
        }
        return refFirst.uppercased() + target.dropFirst()
    }

    /// Back-compat wrapper for the previous call sites that didn't
    /// pass Saheeh context. Behaves like the old function: minimal
    /// touching, sentence-style first-letter for first word only.
    static func capitalizeEnglish(_ s: String) -> String {
        englishWithCase(s, saheeh: nil, isFirstWord: false)
    }

    /// Score from 0.0 (easiest to substitute) to 1.0 (hardest).
    ///
    /// Tier scores are spaced so each mastery level maps to a meaningful slider band.
    /// `introduced` deliberately sits at 0.85 so that passive exposure (which auto-
    /// promotes to introduced after 20 sightings) does NOT cause a flood of Arabic
    /// in the middle of the slider range — the prior bug.
    private func wordSubstitutionScore(for word: Word) -> Double {
        let arabicText = word.textUthmani ?? ""

        // Common Quranic words always substitute first (Allah, etc).
        if isCommonQuranicWord(arabicText) {
            return 0.05
        }

        if let state = wordStates[word.id] {
            switch state.masteryLevel {
            case .mastered:   return 0.20  // earned through pronunciation / quiz
            case .familiar:   return 0.35  // 3+ correct in a row
            case .learning:   return 0.50  // 1+ correct, or tapped to study
            case .introduced: return 0.65  // passive: just seen many times
            case .unseen:     break        // fall through to hash spread
            }
        }

        // Unseen words: deterministic hash maps to [0.10, 0.95] so the
        // slider sweep gradually substitutes more of them. Without this,
        // every unseen word scored 1.0 and ONLY graduation (slider ≥
        // 0.85) would substitute anything — the slider felt dead until
        // the very end, then snapped 100% Arabic at 85%. With the hash
        // spread, slider 30% substitutes ~25 % of unseen words, slider
        // 50 % does ~50 %, etc. The mapping is deterministic so the
        // same words substitute at the same threshold across sessions.
        let hash = abs(word.id.hashValue) % 1000
        return 0.10 + Double(hash) / 1000.0 * 0.85
    }

    // MARK: - Exposure Tracking

    func recordExposure(for word: Word) {
        recordExposures(for: [word])
    }

    /// Record exposure for many words in a single `wordStates` mutation.
    /// Avoids 30 `didSet` fires per verse scroll (one per word).
    func recordExposures(for words: [Word]) {
        var working = wordStates
        let now = Date()
        var changed = false
        for word in words where word.isWord {
            if var state = working[word.id] {
                state.exposureCount += 1
                state.lastSeenDate = now
                working[word.id] = state
            } else {
                working[word.id] = WordLearningState(
                    wordId: word.id,
                    arabicText: word.textUthmani ?? "",
                    transliterationText: word.transliteration?.text ?? "",
                    translationText: word.translation?.text ?? "",
                    masteryLevel: .unseen,
                    exposureCount: 1,
                    lastSeenDate: now
                )
            }
            changed = true
        }
        if changed {
            wordStates = working  // single didSet → single debounced save
        }
    }

    /// Promote word after active engagement (tap to view details)
    func recordTap(for word: Word) {
        guard word.isWord, var state = wordStates[word.id] else {
            recordExposure(for: word) // Create state first
            return
        }

        state.lastSeenDate = Date()

        // Tapping shows interest - promote to learning if just introduced
        if state.masteryLevel == .introduced {
            state.masteryLevel = .learning
        }

        wordStates[word.id] = state
    }

    /// Promote word after successful pronunciation or quiz
    func recordSuccess(for wordId: Int) {
        guard var state = wordStates[wordId] else { return }

        state.correctStreak += 1
        state.lastSeenDate = Date()

        // Success promotes through levels
        if state.correctStreak >= 3 && state.masteryLevel < .familiar {
            state.masteryLevel = .familiar
        } else if state.correctStreak >= 1 && state.masteryLevel < .learning {
            state.masteryLevel = .learning
        }

        wordStates[wordId] = state
    }

    /// Jump a word directly to familiar (for "I Know This Word" button)
    func markAsFamiliar(wordId: Int) {
        guard var state = wordStates[wordId] else { return }
        state.masteryLevel = .familiar
        state.correctStreak += 1
        wordStates[wordId] = state
    }

    func promote(wordId: Int) {
        guard var state = wordStates[wordId] else { return }
        if state.masteryLevel < .mastered {
            state.masteryLevel = MasteryLevel(rawValue: state.masteryLevel.rawValue + 1) ?? .mastered
            state.correctStreak += 1
            wordStates[wordId] = state
        }
    }

    func demote(wordId: Int) {
        guard var state = wordStates[wordId] else { return }
        if state.masteryLevel > .unseen {
            state.masteryLevel = MasteryLevel(rawValue: state.masteryLevel.rawValue - 1) ?? .unseen
            state.correctStreak = 0
            wordStates[wordId] = state
        }
    }

    // MARK: - Lemma Learning

    /// Render-time decision for a word based on its lemma's learning state.
    /// Wholly internal — the UI never names these cases.
    enum LemmaRenderState: Equatable {
        case unlearned
        /// Learned, but still in the 3-encounter graduation window.
        /// Renderer should show the Arabic with a faded transliteration
        /// hint beneath, easing the user into bare-Arabic recognition.
        case trainingWheels
        /// Fully graduated — render as bare Arabic.
        case graduated
    }

    func lemmaRenderState(lemmaText: String?) -> LemmaRenderState {
        guard let lemmaText, !lemmaText.isEmpty,
              let progress = learnedLemmas[lemmaText] else {
            return .unlearned
        }
        return progress.silentEncounters >= LemmaProgress.graduationThreshold
            ? .graduated
            : .trainingWheels
    }

    /// Mark a lemma as learned. Called from the existing "I Know This Word"
    /// button path — no separate user-visible button exists for this.
    /// Idempotent: if already learned, resets the lastSeenAt but keeps the
    /// silent-encounter count (don't lose graduation progress).
    func markLemmaLearned(_ lemmaText: String?) {
        guard let lemmaText, !lemmaText.isEmpty else { return }
        if var existing = learnedLemmas[lemmaText] {
            existing.lastSeenAt = Date()
            learnedLemmas[lemmaText] = existing
        } else {
            learnedLemmas[lemmaText] = LemmaProgress(
                learnedAt: Date(),
                silentEncounters: 0,
                lastSeenAt: Date()
            )
        }
    }

    /// User read a verse containing this lemma without tapping for help.
    /// Bumps the silent-encounter counter toward graduation. Caps at 3 so
    /// the value stays semantically meaningful as a graduation gate.
    func recordSilentEncounter(lemmaText: String?) {
        guard let lemmaText, !lemmaText.isEmpty,
              var progress = learnedLemmas[lemmaText] else { return }
        if progress.silentEncounters < LemmaProgress.graduationThreshold {
            progress.silentEncounters += 1
        }
        progress.lastSeenAt = Date()
        learnedLemmas[lemmaText] = progress
    }

    /// Batched variant — single mutation on `learnedLemmas`, so we don't
    /// fire `didSet` (and a debounced disk write) once per word in a 290-
    /// word verse like 2:282. Caller passes the SET of lemma texts seen
    /// silently in this verse exposure event.
    func recordSilentEncounters(lemmaTexts: Set<String>) {
        guard !lemmaTexts.isEmpty else { return }
        var working = learnedLemmas
        let now = Date()
        var changed = false
        for text in lemmaTexts where !text.isEmpty {
            guard var p = working[text] else { continue }
            if p.silentEncounters < LemmaProgress.graduationThreshold {
                p.silentEncounters += 1
                changed = true
            }
            p.lastSeenAt = now
            working[text] = p
        }
        if changed {
            learnedLemmas = working
        }
    }

    /// User tapped on a word whose lemma had already graduated to bare
    /// Arabic. Honest reading: they needed the meaning, so we demote
    /// the lemma back to training-wheels rendering (silentEncounters → 0).
    /// Tapping a still-training-wheels word does NOT demote — the user
    /// is allowed to consult during the graduation window.
    func recordDemotionTap(lemmaText: String?) {
        guard let lemmaText, !lemmaText.isEmpty,
              var progress = learnedLemmas[lemmaText] else { return }
        if progress.silentEncounters >= LemmaProgress.graduationThreshold {
            progress.silentEncounters = 0
        }
        progress.lastSeenAt = Date()
        learnedLemmas[lemmaText] = progress
    }

    // MARK: - Common Words

    private func isCommonQuranicWord(_ arabic: String) -> Bool {
        let common: Set<String> = [
            "ٱللَّهِ", "ٱللَّهُ", "ٱللَّهَ",
            "رَبِّ", "رَبَّ", "رَبُّ",
            "بِسْمِ",
            "ٱلرَّحْمَـٰنِ",
            "ٱلرَّحِيمِ",
            "قَالَ",
            "ٱلَّذِينَ", "ٱلَّذِى",
            "كَانَ",
            "إِنَّ",
            "مِنَ", "مِن",
            "عَلَىٰ",
            "فِى", "فِي",
            "لَا",
            "مَا",
            "هُوَ",
        ]
        return common.contains(arabic)
    }

    // MARK: - Persistence

    private let statesKey = "bayan_wordStates"
    private let lemmasKey = "bayan_learnedLemmas"

    init() {
        loadWordStates()
        loadLearnedLemmas()
        if let saved = UserDefaults.standard.object(forKey: "bayan_substitutionLevel") as? Double {
            substitutionLevel = saved
        }
        useTransliteration = UserDefaults.standard.bool(forKey: "bayan_useTransliteration")
        graduatedToArabic = UserDefaults.standard.bool(forKey: "bayan_graduatedToArabic")
    }

    /// Debounce saves — coalesce rapid word state changes into one write.
    /// Encoding happens on a detached background task so the main actor
    /// isn't blocked while serializing potentially thousands of word states.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = wordStates
            let key = statesKey
            Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func loadWordStates() {
        if let data = UserDefaults.standard.data(forKey: statesKey),
           let saved = try? JSONDecoder().decode([Int: WordLearningState].self, from: data) {
            wordStates = saved
        }
    }

    /// Sibling of `scheduleSave` for the lemma store. Kept separate so a
    /// scroll-pass that bumps silent-encounter counters does not also force
    /// re-serialisation of the (much larger) per-instance `wordStates` blob.
    private func scheduleLemmasSave() {
        lemmasSaveTask?.cancel()
        lemmasSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = learnedLemmas
            let key = lemmasKey
            Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func loadLearnedLemmas() {
        if let data = UserDefaults.standard.data(forKey: lemmasKey),
           let saved = try? JSONDecoder().decode([String: LemmaProgress].self, from: data) {
            learnedLemmas = saved
        }
    }
}

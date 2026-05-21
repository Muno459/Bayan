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

    private var saveTask: Task<Void, Never>?

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
    func displayMode(for word: Word) -> SubstitutionDisplay {
        guard word.isWord else {
            return .english(Self.capitalizeEnglish(word.translation?.text ?? ""))
        }

        // Quran Foundation's word-by-word translations come in lowercase
        // ("in", "the", "name", "of", "allah"). When rendered as one word
        // per cell in the substitution grid, lowercase looks unfinished
        // and reads oddly. Title-case each word so "in the name of allah"
        // renders as "In The Name Of Allah" — matches how proper Quran
        // translations are typeset.
        let englishText = Self.capitalizeEnglish(word.translation?.text ?? "")
        let arabicText = word.textUthmani ?? word.textImlaei ?? ""
        let transliterationText = word.transliteration?.text ?? arabicText

        // The user picked their learning track in Settings / Onboarding —
        // Arabic Script or Transliteration. That choice is absolute: a
        // substituted word becomes the chosen target, NOT a stepping
        // stone that flips into Arabic once the word is "comfortable".
        // The previous logic silently broke the user's preference once
        // they got good at a word.
        let substitutedTarget = useTransliteration ? transliterationText : arabicText

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

    /// Title-case a word from QF's lowercase word-by-word translations.
    /// Preserves any all-caps abbreviations (e.g. "TM"), proper-noun
    /// capitals from the API, and parenthetical insertions like "(Adam)".
    static func capitalizeEnglish(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return s }
        // `localizedCapitalized` handles unicode + locale-aware first
        // letter casing per word, matches Apple convention.
        return trimmed.localizedCapitalized
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

    init() {
        loadWordStates()
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
}

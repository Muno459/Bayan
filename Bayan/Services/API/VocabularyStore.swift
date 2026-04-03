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
    var substitutionLevel: Double = 0.3 {
        didSet { UserDefaults.standard.set(substitutionLevel, forKey: "bayan_substitutionLevel") }
    }

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

    /// Determine display for a word. The substitution level slider is king.
    ///
    /// At level 0.0: everything is English
    /// At level 0.3: common words (Allah, Rabb) become Arabic script
    /// At level 0.5: common + frequently-seen words become Arabic
    /// At level 0.7: most words become Arabic, rare ones transition
    /// At level 1.0: everything is Arabic script
    func displayMode(for word: Word) -> SubstitutionDisplay {
        guard word.isWord else {
            return .english(word.translation?.text ?? "")
        }

        let englishText = word.translation?.text ?? ""
        let arabicText = word.textUthmani ?? word.textImlaei ?? ""

        if substitutionLevel < 0.05 {
            return .english(englishText)
        }

        if substitutionLevel >= 0.95 {
            return .arabic(arabicText)
        }

        let wordScore = wordSubstitutionScore(for: word)

        if wordScore <= substitutionLevel {
            return .arabic(arabicText)
        } else if wordScore <= substitutionLevel + 0.2 {
            return .transitioning(arabic: arabicText, english: englishText)
        } else {
            return .english(englishText)
        }
    }

    /// Score from 0.0 (easiest to substitute) to 1.0 (hardest).
    private func wordSubstitutionScore(for word: Word) -> Double {
        let arabicText = word.textUthmani ?? ""

        if isCommonQuranicWord(arabicText) {
            return 0.05
        }

        if let state = wordStates[word.id] {
            switch state.masteryLevel {
            case .mastered: return 0.1
            case .familiar: return 0.25
            case .learning: return 0.45
            case .introduced: return 0.65
            case .unseen: return 0.8
            }
        }

        return 0.85
    }

    // MARK: - Exposure Tracking

    func recordExposure(for word: Word) {
        guard word.isWord else { return }

        if var state = wordStates[word.id] {
            state.exposureCount += 1
            state.lastSeenDate = Date()

            // Auto-promote requires sustained engagement, not just scrolling past
            if state.exposureCount >= 50 && state.masteryLevel < .familiar {
                state.masteryLevel = .familiar
            } else if state.exposureCount >= 25 && state.masteryLevel < .learning {
                state.masteryLevel = .learning
            } else if state.exposureCount >= 10 && state.masteryLevel < .introduced {
                state.masteryLevel = .introduced
            }

            wordStates[word.id] = state
        } else {
            wordStates[word.id] = WordLearningState(
                wordId: word.id,
                arabicText: word.textUthmani ?? "",
                translationText: word.translation?.text ?? "",
                masteryLevel: .unseen,
                exposureCount: 1,
                lastSeenDate: Date()
            )
        }
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
    }

    /// Debounce saves — coalesce rapid word state changes into one write
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveWordStates()
        }
    }

    private func saveWordStates() {
        if let data = try? JSONEncoder().encode(wordStates) {
            UserDefaults.standard.set(data, forKey: statesKey)
        }
    }

    private func loadWordStates() {
        if let data = UserDefaults.standard.data(forKey: statesKey),
           let saved = try? JSONDecoder().decode([Int: WordLearningState].self, from: data) {
            wordStates = saved
        }
    }
}

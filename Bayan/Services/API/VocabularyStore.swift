import Foundation
import SwiftUI

/// Manages vocabulary learning states and the progressive substitution engine
@MainActor
@Observable
final class VocabularyStore {
    /// All known word learning states, keyed by word ID
    private(set) var wordStates: [Int: WordLearningState] = [:]

    /// Current substitution level (0.0 = all English, 1.0 = all Arabic)
    var substitutionLevel: Double = 0.0

    /// Total unique words encountered
    var totalWordsEncountered: Int { wordStates.count }

    /// Words at each mastery level
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

    /// Determine how a word should be displayed based on learning state
    func displayMode(for word: Word) -> SubstitutionDisplay {
        guard word.isWord else {
            // Verse end markers — show as-is
            return .english(word.translation?.text ?? "")
        }

        let arabicText = word.textUthmani ?? word.textImlaei ?? ""
        let englishText = word.translation?.text ?? ""

        // Check if we have a learning state for this word
        if let state = wordStates[word.id] {
            switch state.masteryLevel {
            case .mastered, .familiar:
                return .arabic(arabicText)
            case .learning:
                return .transitioning(arabic: arabicText, english: englishText)
            case .introduced, .unseen:
                return .english(englishText)
            }
        }

        // Word not yet seen — use substitution level as threshold
        // Common Quranic words (Allah, Rabb, etc.) are shown in Arabic earlier
        if isCommonQuranicWord(arabicText) && substitutionLevel >= 0.1 {
            return .arabic(arabicText)
        }

        if substitutionLevel >= 0.8 {
            return .arabic(arabicText)
        } else if substitutionLevel >= 0.5 {
            return .transitioning(arabic: arabicText, english: englishText)
        } else {
            return .english(englishText)
        }
    }

    /// Record that the user has seen a word
    func recordExposure(for word: Word) {
        guard word.isWord else { return }

        if var state = wordStates[word.id] {
            state.exposureCount += 1
            state.lastSeenDate = Date()

            // Auto-promote based on exposure
            if state.exposureCount >= 20 && state.masteryLevel < .familiar {
                state.masteryLevel = .familiar
            } else if state.exposureCount >= 10 && state.masteryLevel < .learning {
                state.masteryLevel = .learning
            } else if state.exposureCount >= 3 && state.masteryLevel < .introduced {
                state.masteryLevel = .introduced
            }

            wordStates[word.id] = state
        } else {
            // First time seeing this word
            wordStates[word.id] = WordLearningState(
                wordId: word.id,
                arabicText: word.textUthmani ?? "",
                translationText: word.translation?.text ?? "",
                transliterationText: word.transliteration?.text ?? "",
                masteryLevel: .unseen,
                exposureCount: 1,
                lastSeenDate: Date()
            )
        }
    }

    /// Manually promote a word's mastery level
    func promote(wordId: Int) {
        guard var state = wordStates[wordId] else { return }
        if state.masteryLevel < .mastered {
            state.masteryLevel = MasteryLevel(rawValue: state.masteryLevel.rawValue + 1) ?? .mastered
            state.correctStreak += 1
            wordStates[wordId] = state
        }
    }

    /// Manually demote a word's mastery level
    func demote(wordId: Int) {
        guard var state = wordStates[wordId] else { return }
        if state.masteryLevel > .unseen {
            state.masteryLevel = MasteryLevel(rawValue: state.masteryLevel.rawValue - 1) ?? .unseen
            state.correctStreak = 0
            wordStates[wordId] = state
        }
    }

    // MARK: - Common Words

    /// Words that appear frequently across the Quran — teach these first
    private func isCommonQuranicWord(_ arabic: String) -> Bool {
        let commonWords: Set<String> = [
            "ٱللَّهِ", "ٱللَّهُ", "ٱللَّهَ", // Allah
            "رَبِّ", "رَبَّ", "رَبُّ", // Lord
            "قَالَ", // said
            "ٱلَّذِينَ", "ٱلَّذِى", // those who / the one who
            "كَانَ", // was
            "إِنَّ", // indeed
            "مِنَ", "مِن", // from
            "عَلَىٰ", // upon
            "فِى", "فِي", // in
            "لَا", // no/not
            "مَا", // what/not
            "هُوَ", // he
            "بِسْمِ", // in the name of
            "ٱلرَّحْمَـٰنِ", // The Most Gracious
            "ٱلرَّحِيمِ", // The Most Merciful
        ]
        return commonWords.contains(arabic)
    }
}

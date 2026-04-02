import Foundation
import SwiftUI

/// Manages vocabulary learning states and the progressive substitution engine.
///
/// The core idea: users start reading entirely in English. As they encounter
/// Arabic words repeatedly (through reading + audio), English words are gradually
/// replaced with their transliterated Arabic equivalents (phonetic spelling),
/// NOT Arabic script. This lets non-Arabic readers build vocabulary through
/// sound recognition.
///
/// Journey per word: English → English+transliteration → transliteration only
@MainActor
@Observable
final class VocabularyStore {
    /// All known word learning states, keyed by word ID
    private(set) var wordStates: [Int: WordLearningState] = [:]

    /// Current substitution level (0.0 = all English, 1.0 = all transliteration)
    var substitutionLevel: Double = 0.3

    /// Total unique words encountered
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

    /// Determine how a word should be displayed.
    /// Returns English, transitioning (translit + English hint), or transliteration only.
    func displayMode(for word: Word) -> SubstitutionDisplay {
        guard word.isWord else {
            return .english(word.translation?.text ?? "")
        }

        let englishText = word.translation?.text ?? ""
        let translitText = word.transliteration?.text ?? englishText

        // If we have a learning state for this word, use mastery level
        if let state = wordStates[word.id] {
            switch state.masteryLevel {
            case .mastered, .familiar:
                return .transliteration(translitText)
            case .learning:
                return .transitioning(transliteration: translitText, english: englishText)
            case .introduced, .unseen:
                return .english(englishText)
            }
        }

        // Word not yet tracked — use global substitution level + common word detection
        if isCommonQuranicWord(translitText) && substitutionLevel >= 0.1 {
            return .transliteration(translitText)
        }

        if substitutionLevel >= 0.7 {
            return .transliteration(translitText)
        } else if substitutionLevel >= 0.4 {
            return .transitioning(transliteration: translitText, english: englishText)
        } else {
            return .english(englishText)
        }
    }

    /// Record that the user has seen/heard a word
    func recordExposure(for word: Word) {
        guard word.isWord else { return }

        if var state = wordStates[word.id] {
            state.exposureCount += 1
            state.lastSeenDate = Date()

            // Auto-promote based on repeated exposure
            if state.exposureCount >= 25 && state.masteryLevel < .familiar {
                state.masteryLevel = .familiar
            } else if state.exposureCount >= 12 && state.masteryLevel < .learning {
                state.masteryLevel = .learning
            } else if state.exposureCount >= 4 && state.masteryLevel < .introduced {
                state.masteryLevel = .introduced
            }

            wordStates[word.id] = state
        } else {
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

    /// High-frequency Quranic words that get substituted early.
    /// Users hear these constantly — "Allah", "Rabb", "bismillah" etc.
    private func isCommonQuranicWord(_ transliteration: String) -> Bool {
        let common: Set<String> = [
            "l-lahi", "lillahi", "l-lahu", "allahu", "allah",
            "rabbi", "rabba", "rabbu",
            "bis'mi", "bismi",
            "l-rahmani", "al-rahmani",
            "l-rahimi", "al-rahimi",
            "qala",
            "alladhina",
            "kana",
            "inna",
            "min", "mina",
            "ala", "'ala",
            "fi",
            "la",
            "ma",
            "huwa",
        ]
        return common.contains(transliteration.lowercased())
    }
}

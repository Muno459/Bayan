import Foundation
import SwiftUI

/// Manages vocabulary learning and the progressive substitution engine.
///
/// The substitution level slider is the PRIMARY control. It determines
/// what percentage of words show as transliteration vs English.
/// Individual word mastery adjusts within that — learned words get
/// substituted first, unknown words last.
@MainActor
@Observable
final class VocabularyStore {
    private(set) var wordStates: [Int: WordLearningState] = [:] {
        didSet { saveWordStates() }
    }

    /// 0.0 = all English, 1.0 = all transliteration.
    /// This is the MAIN control the user interacts with.
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
    /// At level 0.3: common words (Allah, Rabb, bismillah) become transliteration
    /// At level 0.5: common + frequently-seen words become transliteration
    /// At level 0.7: most words become transliteration, rare ones transition
    /// At level 1.0: everything is transliteration
    func displayMode(for word: Word) -> SubstitutionDisplay {
        guard word.isWord else {
            return .english(word.translation?.text ?? "")
        }

        let englishText = word.translation?.text ?? ""
        let translitText = word.transliteration?.text ?? englishText

        // Level 0 = pure English, no substitution at all
        if substitutionLevel < 0.05 {
            return .english(englishText)
        }

        // Level 1.0 = pure transliteration, everything substituted
        if substitutionLevel >= 0.95 {
            return .transliteration(translitText)
        }

        // In between: use a score per word to decide
        let wordScore = wordSubstitutionScore(for: word)

        if wordScore <= substitutionLevel {
            // This word gets substituted to transliteration
            return .transliteration(translitText)
        } else if wordScore <= substitutionLevel + 0.2 {
            // Close to the threshold — show transitioning
            return .transitioning(transliteration: translitText, english: englishText)
        } else {
            return .english(englishText)
        }
    }

    /// Score from 0.0 (easiest to substitute) to 1.0 (hardest).
    /// Lower score = gets substituted earlier (at lower slider values).
    private func wordSubstitutionScore(for word: Word) -> Double {
        let translitText = word.transliteration?.text ?? ""

        // Common Quranic words are easiest — substitute first
        if isCommonQuranicWord(translitText) {
            return 0.05
        }

        // Check mastery from exposure history
        if let state = wordStates[word.id] {
            switch state.masteryLevel {
            case .mastered: return 0.1
            case .familiar: return 0.25
            case .learning: return 0.45
            case .introduced: return 0.65
            case .unseen: return 0.8
            }
        }

        // Never seen — hardest to substitute
        return 0.85
    }

    // MARK: - Exposure Tracking

    func recordExposure(for word: Word) {
        guard word.isWord else { return }

        if var state = wordStates[word.id] {
            state.exposureCount += 1
            state.lastSeenDate = Date()

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

    private func isCommonQuranicWord(_ transliteration: String) -> Bool {
        let common: Set<String> = [
            "l-lahi", "lillahi", "l-lahu", "allahu", "allah",
            "rabbi", "rabba", "rabbu",
            "bis'mi", "bismi",
            "l-raḥmāni", "al-rahmani", "l-rahmani",
            "l-raḥīmi", "al-rahimi", "l-rahimi",
            "qāla", "qala",
            "alladhīna", "alladhina",
            "kāna", "kana",
            "inna",
            "min", "mina",
            "ʿalā", "ala", "'ala",
            "fī", "fi",
            "lā", "la",
            "mā", "ma",
            "huwa",
        ]
        return common.contains(transliteration.lowercased())
    }

    // MARK: - Persistence

    private let statesKey = "bayan_wordStates"

    init() {
        loadWordStates()
        if let saved = UserDefaults.standard.object(forKey: "bayan_substitutionLevel") as? Double {
            substitutionLevel = saved
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

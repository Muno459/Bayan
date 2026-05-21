import Foundation

/// Tracks the learning state of a single Arabic word
struct WordLearningState: Codable, Sendable {
    let wordId: Int
    let arabicText: String
    let transliterationText: String
    let translationText: String
    var masteryLevel: MasteryLevel
    var exposureCount: Int
    var lastSeenDate: Date?
    var correctStreak: Int

    init(
        wordId: Int,
        arabicText: String,
        transliterationText: String = "",
        translationText: String,
        masteryLevel: MasteryLevel = .unseen,
        exposureCount: Int = 0,
        lastSeenDate: Date? = nil,
        correctStreak: Int = 0
    ) {
        self.wordId = wordId
        self.arabicText = arabicText
        self.transliterationText = transliterationText
        self.translationText = translationText
        self.masteryLevel = masteryLevel
        self.exposureCount = exposureCount
        self.lastSeenDate = lastSeenDate
        self.correctStreak = correctStreak
    }
}

enum MasteryLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case unseen = 0
    case introduced = 1   // Seen a few times, still English
    case learning = 2     // Shows Arabic with English hint below
    case familiar = 3     // Shows Arabic only
    case mastered = 4     // Confidently reads Arabic

    static func < (lhs: MasteryLevel, rhs: MasteryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .unseen: "New"
        case .introduced: "Introduced"
        case .learning: "Learning"
        case .familiar: "Familiar"
        case .mastered: "Mastered"
        }
    }
}

/// How a word appears in the reading view.
/// Arabic mode: English → Arabic script
/// Transliteration mode: English → transliterated pronunciation
enum SubstitutionDisplay: Sendable {
    /// Show English translation (word not yet learned)
    case english(String)
    /// Learning — show target with small English hint below
    case transitioning(target: String, english: String)
    /// Learned — show target only (Arabic script or transliteration)
    case learned(String)
}

import Foundation

/// Tracks the learning state of a single Arabic word
struct WordLearningState: Codable, Sendable {
    let wordId: Int
    let arabicText: String
    let translationText: String
    let transliterationText: String
    var masteryLevel: MasteryLevel
    var exposureCount: Int
    var lastSeenDate: Date?
    var correctStreak: Int

    init(
        wordId: Int,
        arabicText: String,
        translationText: String,
        transliterationText: String,
        masteryLevel: MasteryLevel = .unseen,
        exposureCount: Int = 0,
        lastSeenDate: Date? = nil,
        correctStreak: Int = 0
    ) {
        self.wordId = wordId
        self.arabicText = arabicText
        self.translationText = translationText
        self.transliterationText = transliterationText
        self.masteryLevel = masteryLevel
        self.exposureCount = exposureCount
        self.lastSeenDate = lastSeenDate
        self.correctStreak = correctStreak
    }
}

enum MasteryLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case unseen = 0
    case introduced = 1
    case learning = 2
    case familiar = 3
    case mastered = 4

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

    /// Minimum mastery to show Arabic instead of English in substitution
    var showsArabic: Bool {
        self >= .familiar
    }
}

/// Represents how a word should be displayed in the progressive substitution view
enum SubstitutionDisplay: Sendable {
    case english(String)
    case arabic(String)
    case transitioning(arabic: String, english: String)
}

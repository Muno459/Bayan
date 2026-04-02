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
    case introduced = 1   // Seen a few times, still English
    case learning = 2     // Shows transliteration with English hint below
    case familiar = 3     // Shows transliteration only
    case mastered = 4     // Shows transliteration confidently, optional Arabic script

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
/// The journey: English -> English+transliteration -> transliteration -> transliteration (confident)
enum SubstitutionDisplay: Sendable {
    /// User hasn't learned this word yet — show English translation
    case english(String)
    /// User is learning — show transliteration with small English hint
    case transitioning(transliteration: String, english: String)
    /// User knows this word — show transliteration only
    case transliteration(String)
}

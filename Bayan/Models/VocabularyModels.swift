import Foundation

/// Tracks the learning state of a single Arabic word
struct WordLearningState: Codable, Sendable {
    let wordId: Int
    let arabicText: String
    let translationText: String
    var masteryLevel: MasteryLevel
    var exposureCount: Int
    var lastSeenDate: Date?
    var correctStreak: Int

    init(
        wordId: Int,
        arabicText: String,
        translationText: String,
        masteryLevel: MasteryLevel = .unseen,
        exposureCount: Int = 0,
        lastSeenDate: Date? = nil,
        correctStreak: Int = 0
    ) {
        self.wordId = wordId
        self.arabicText = arabicText
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

/// The 3-stage tap learning progression (based on cognitive science research).
/// Stage 1: Errorless exposure — tap instantly shows meaning (encounters 1-5)
/// Stage 2: Guided generation — brief pause, then reveal (encounters 5-12)  
/// Stage 3: Active retrieval — recall before reveal (encounters 12+)
enum TapLearningStage: Sendable {
    case errorless    // Immediate reveal, no guessing
    case guided       // Brief pause before reveal
    case retrieval    // User must try to recall first

    static func forExposureCount(_ count: Int) -> TapLearningStage {
        if count < 5 { return .errorless }
        if count < 12 { return .guided }
        return .retrieval
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

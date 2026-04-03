import Foundation
import Testing
@testable import Bayan

// MARK: - Vocabulary Store Tests

@Suite("VocabularyStore")
struct VocabularyStoreTests {

    private func makeWord(id: Int, arabic: String = "بِسْمِ", english: String = "In the name") -> Word {
        Word(
            id: id, position: 1,
            textUthmani: arabic, textImlaei: nil,
            translation: WordTranslation(text: english, languageName: "english"),
            transliteration: nil,
            charTypeName: "word"
        )
    }

    @Test("Substitution level 0 returns all English")
    @MainActor
    func allEnglish() {
        let store = VocabularyStore()
        store.substitutionLevel = 0.0
        let display = store.displayMode(for: makeWord(id: 1))
        if case .english(let text) = display {
            #expect(text == "In the name")
        } else {
            Issue.record("Expected .english at level 0")
        }
    }

    @Test("Substitution level 1 returns all Arabic")
    @MainActor
    func allArabic() {
        let store = VocabularyStore()
        store.substitutionLevel = 1.0
        let display = store.displayMode(for: makeWord(id: 2, arabic: "ٱلرَّحِيمِ", english: "the Most Merciful"))
        if case .learned(let text) = display {
            #expect(text == "ٱلرَّحِيمِ")
        } else {
            Issue.record("Expected .learned at level 1.0")
        }
    }

    @Test("Common words substitute at low levels")
    @MainActor
    func commonWords() {
        let store = VocabularyStore()
        store.substitutionLevel = 0.1

        let allah = makeWord(id: 3, arabic: "ٱللَّهِ", english: "(of) Allah")
        let display = store.displayMode(for: allah)
        if case .learned = display {
            // Common word should show learned even at low level
        } else {
            Issue.record("Expected .learned for common word 'Allah' at level 0.1")
        }
    }

    @Test("Word exposure tracking increments count")
    @MainActor
    func exposureTracking() {
        let store = VocabularyStore()
        let word = makeWord(id: 10)

        store.recordExposure(for: word)
        #expect(store.wordStates[10]?.exposureCount == 1)
        #expect(store.wordStates[10]?.masteryLevel == .unseen)

        // 10 exposures -> introduced
        for _ in 0..<9 { store.recordExposure(for: word) }
        #expect(store.wordStates[10]?.exposureCount == 10)
        #expect(store.wordStates[10]?.masteryLevel == .introduced)
    }

    @Test("Promote and demote mastery")
    @MainActor
    func promoteAndDemote() {
        let store = VocabularyStore()
        let word = makeWord(id: 20)
        store.recordExposure(for: word)

        store.promote(wordId: 20)
        #expect(store.wordStates[20]?.masteryLevel == .introduced)

        store.promote(wordId: 20)
        #expect(store.wordStates[20]?.masteryLevel == .learning)

        store.demote(wordId: 20)
        #expect(store.wordStates[20]?.masteryLevel == .introduced)
    }

    @Test("Non-word characters return English")
    @MainActor
    func nonWord() {
        let store = VocabularyStore()
        store.substitutionLevel = 1.0

        let endMarker = Word(
            id: 99, position: 5,
            textUthmani: "۝", textImlaei: nil,
            translation: WordTranslation(text: "", languageName: "english"),
            transliteration: nil,
            charTypeName: "end"
        )
        let display = store.displayMode(for: endMarker)
        if case .english = display { } else {
            Issue.record("Non-word should always return .english")
        }
    }

    @Test("Mastery counts are correct")
    @MainActor
    func masteryCounts() {
        let store = VocabularyStore()
        // Use unique IDs that won't collide with persisted data
        let baseId = 90000
        for i in 0..<5 {
            let word = makeWord(id: baseId + i)
            store.recordExposure(for: word)
        }

        // Promote some
        store.promote(wordId: baseId) // -> introduced
        store.promote(wordId: baseId) // -> learning
        store.promote(wordId: baseId) // -> familiar
        store.promote(wordId: baseId) // -> mastered

        store.promote(wordId: baseId + 1) // -> introduced
        store.promote(wordId: baseId + 1) // -> learning
        store.promote(wordId: baseId + 1) // -> familiar

        // Check only our test words
        let testStates = (0..<5).compactMap { store.wordStates[baseId + $0] }
        let mastered = testStates.filter { $0.masteryLevel == .mastered }.count
        let familiar = testStates.filter { $0.masteryLevel == .familiar }.count
        #expect(mastered == 1)
        #expect(familiar == 1)
    }
}

// MARK: - Model Tests

@Suite("Models")
struct ModelTests {

    @Test("Chapter decoding")
    func chapterDecoding() throws {
        let json = """
        {"id":1,"name_simple":"Al-Fatihah","name_arabic":"الفاتحة","verses_count":7,"revelation_place":"makkah","revelation_order":5}
        """.data(using: .utf8)!
        let chapter = try JSONDecoder().decode(Chapter.self, from: json)
        #expect(chapter.id == 1)
        #expect(chapter.nameSimple == "Al-Fatihah")
        #expect(chapter.nameArabic == "الفاتحة")
        #expect(chapter.versesCount == 7)
        #expect(chapter.revelationPlace == "makkah")
    }

    @Test("Word timing parsing")
    func wordTimings() throws {
        let json = """
        {"verse_key":"1:1","timestamp_from":0,"timestamp_to":5000,"segments":[[1,0,500],[2,500,1200],[3,1200,2000]]}
        """.data(using: .utf8)!
        let ts = try JSONDecoder().decode(VerseTimestamp.self, from: json)
        #expect(ts.verseKey == "1:1")
        #expect(ts.wordTimings.count == 3)
        #expect(ts.wordTimings[0].wordIndex == 1)
        #expect(ts.wordTimings[0].startMs == 0)
        #expect(ts.wordTimings[0].endMs == 500)
    }

    @Test("Malformed segments are skipped")
    func malformedSegments() throws {
        let json = """
        {"verse_key":"1:1","timestamp_from":0,"timestamp_to":5000,"segments":[[1,0],[2,500,1200]]}
        """.data(using: .utf8)!
        let ts = try JSONDecoder().decode(VerseTimestamp.self, from: json)
        #expect(ts.wordTimings.count == 1) // Only the valid segment
    }

    @Test("Reciter decoding")
    func reciterDecoding() throws {
        let json = """
        {"id":7,"name":"Mishari Rashid al-Afasy","style":{"name":"Murattal","language_name":"english"},"translated_name":{"name":"Mishari","language_name":"english"}}
        """.data(using: .utf8)!
        let reciter = try JSONDecoder().decode(Reciter.self, from: json)
        #expect(reciter.id == 7)
        #expect(reciter.name == "Mishari Rashid al-Afasy")
        #expect(reciter.style?.name == "Murattal")
        #expect(reciter.displayName == "Mishari Rashid al-Afasy (Murattal)")
    }

    @Test("MasteryLevel ordering")
    func masteryOrdering() {
        #expect(MasteryLevel.unseen < MasteryLevel.introduced)
        #expect(MasteryLevel.introduced < MasteryLevel.learning)
        #expect(MasteryLevel.learning < MasteryLevel.familiar)
        #expect(MasteryLevel.familiar < MasteryLevel.mastered)
    }

    @Test("WordLearningState codable roundtrip")
    func learningStateCodable() throws {
        let state = WordLearningState(
            wordId: 42,
            arabicText: "بِسْمِ",
            translationText: "In the name",
            masteryLevel: .learning,
            exposureCount: 15,
            correctStreak: 3
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WordLearningState.self, from: data)
        #expect(decoded.wordId == 42)
        #expect(decoded.masteryLevel == .learning)
        #expect(decoded.exposureCount == 15)
        #expect(decoded.correctStreak == 3)
    }
}

// MARK: - Arabic Letter Data Tests

@Suite("ArabicLetterData")
struct ArabicLetterTests {

    @Test("Letter breakdown for Bismillah")
    func bismillahBreakdown() {
        let breakdown = ArabicLetterData.breakdownWord("بِسْمِ")
        #expect(breakdown.count >= 3) // At least ba, sin, meem
        #expect(breakdown[0].letterName == "Ba")
    }

    @Test("Diacritics are detected")
    func diacritics() {
        let kasrah = ArabicLetterData.diacritics["\u{0650}"]
        #expect(kasrah == "Kasrah (i)")

        let shaddah = ArabicLetterData.diacritics["\u{0651}"]
        #expect(shaddah == "Shaddah (double)")
    }

    @Test("No duplicate keys in letter map")
    func noDuplicateKeys() {
        // This test ensures the dictionary init doesn't crash
        // (duplicate keys would cause a runtime crash in dictionary literals)
        let count = ArabicLetterData.letters.count
        #expect(count > 25) // At least 28 Arabic letters
    }
}

// MARK: - Quranic Word Data Tests

@Suite("QuranicWordData")
struct QuranicWordDataTests {

    @Test("Allah frequency is high")
    func allahFrequency() {
        let freq = QuranicWordData.frequency(for: "ٱللَّهِ")
        #expect(freq != nil)
        #expect(freq! > 1000)
    }

    @Test("Unknown word returns nil frequency")
    func unknownFrequency() {
        let freq = QuranicWordData.frequency(for: "nonexistent")
        #expect(freq == nil)
    }
}

// MARK: - User Store Tests

@Suite("UserStore")
struct UserStoreTests {

    @Test("Bookmark toggle")
    @MainActor
    func bookmarkToggle() {
        let store = UserStore()
        #expect(!store.isBookmarked("1:1"))

        store.toggleBookmark(verseKey: "1:1", chapterId: 1, verseNumber: 1)
        #expect(store.isBookmarked("1:1"))

        store.toggleBookmark(verseKey: "1:1", chapterId: 1, verseNumber: 1)
        #expect(!store.isBookmarked("1:1"))
    }

    @Test("Reading session lifecycle")
    @MainActor
    func sessionLifecycle() {
        let store = UserStore()
        let initialCount = store.sessions.count

        store.startSession(chapterId: 1, verseKey: "1:1")
        #expect(store.activeSession != nil)
        #expect(store.activeSession?.chapterId == 1)

        store.endCurrentSession()
        #expect(store.activeSession == nil)
        #expect(store.sessions.count == initialCount + 1)
    }
}

// MARK: - Milestone Tests

@Suite("Milestones")
struct MilestoneTests {

    @Test("First word milestone triggers")
    func firstWord() {
        let m = VocabularyMilestone.check(oldCount: 0, newCount: 1)
        #expect(m != nil)
        #expect(m?.title == "First Word!")
    }

    @Test("10 words milestone")
    func tenWords() {
        let m = VocabularyMilestone.check(oldCount: 9, newCount: 10)
        #expect(m != nil)
        #expect(m?.title == "10 Words!")
    }

    @Test("No milestone between thresholds")
    func noMilestone() {
        let m = VocabularyMilestone.check(oldCount: 6, newCount: 7)
        #expect(m == nil)
    }

    @Test("100 words milestone")
    func hundredWords() {
        let m = VocabularyMilestone.check(oldCount: 99, newCount: 100)
        #expect(m != nil)
        #expect(m?.title == "100 Words!")
    }
}

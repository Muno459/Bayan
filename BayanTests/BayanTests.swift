import Testing
@testable import Bayan

@Suite("Vocabulary Store Tests")
struct VocabularyStoreTests {
    @Test("Word mastery level promotion")
    @MainActor
    func testMasteryPromotion() {
        let store = VocabularyStore()

        let word = Word(
            id: 1,
            position: 1,
            textUthmani: "بِسْمِ",
            textImlaei: nil,
            translation: WordTranslation(text: "In the name", languageName: "english"),
            transliteration: nil,
            charTypeName: "word"
        )

        // First exposure
        store.recordExposure(for: word)
        #expect(store.wordStates[1]?.masteryLevel == .unseen)
        #expect(store.wordStates[1]?.exposureCount == 1)

        // After 4 exposures -> introduced
        store.recordExposure(for: word)
        store.recordExposure(for: word)
        store.recordExposure(for: word)
        #expect(store.wordStates[1]?.masteryLevel == .introduced)

        // Manual promote
        store.promote(wordId: 1)
        #expect(store.wordStates[1]?.masteryLevel == .learning)
    }

    @Test("Substitution level 0 returns all English")
    @MainActor
    func testSubstitutionAllEnglish() {
        let store = VocabularyStore()
        store.substitutionLevel = 0.0

        let word = Word(
            id: 100,
            position: 1,
            textUthmani: "ٱللَّهِ",
            textImlaei: nil,
            translation: WordTranslation(text: "Allah", languageName: "english"),
            transliteration: nil,
            charTypeName: "word"
        )

        let display = store.displayMode(for: word)
        if case .english(let text) = display {
            #expect(text == "Allah")
        } else {
            Issue.record("Expected .english at level 0")
        }
    }

    @Test("Substitution level 1 returns all Arabic")
    @MainActor
    func testSubstitutionAllArabic() {
        let store = VocabularyStore()
        store.substitutionLevel = 1.0

        let word = Word(
            id: 200,
            position: 1,
            textUthmani: "ٱلرَّحِيمِ",
            textImlaei: nil,
            translation: WordTranslation(text: "the Most Merciful", languageName: "english"),
            transliteration: nil,
            charTypeName: "word"
        )

        let display = store.displayMode(for: word)
        if case .arabic(let text) = display {
            #expect(text == "ٱلرَّحِيمِ")
        } else {
            Issue.record("Expected .arabic at level 1.0")
        }
    }
}

import Foundation

struct Verse: Codable, Identifiable, Sendable {
    let id: Int
    let verseKey: String
    let verseNumber: Int
    let textUthmani: String?
    let textImlaei: String?
    let words: [Word]?
    let translations: [Translation]?

    enum CodingKeys: String, CodingKey {
        case id
        case verseKey = "verse_key"
        case verseNumber = "verse_number"
        case textUthmani = "text_uthmani"
        case textImlaei = "text_imlaei"
        case words
        case translations
    }
}

struct Word: Codable, Identifiable, Sendable {
    let id: Int
    let position: Int
    let textUthmani: String?
    let textImlaei: String?
    let translation: WordTranslation?
    let transliteration: WordTransliteration?
    let charTypeName: String?

    // Morphology (from QUL: word_roots / word_lemmas joined onto roots / lemmas).
    // All optional — pre-ingest builds and char_type != 'word' rows will be nil,
    // and pronouns/particles legitimately have no triliteral root.
    let lemmaId: Int?
    let lemmaText: String?      // diacritized form, e.g. "اللَّه" — stable lookup key
    let rootId: Int?
    let rootArabic: String?     // single-space normalized, e.g. "ا ل ه"

    // LLM-produced verse-translation-aware English alignment
    // (cc/claude-opus-4-7 over Saheeh International, table word_translations_aligned).
    // The English slice here is contiguous Saheeh that this Arabic word "owns",
    // making the per-word English read like natural English instead of the
    // choppy "That (is) the Book no doubt in it" we got from the WBW table.
    // Falls back to the WBW `translation` field when this row is missing.
    let alignedEnglish: String?
    let alignedIsImplicit: Bool?      // bracketed translator clarification
    let alignedTrailingPunctuation: String?
    let alignmentConfidence: String?  // "high" | "medium" | "low"

    enum CodingKeys: String, CodingKey {
        case id
        case position
        case textUthmani = "text_uthmani"
        case textImlaei = "text_imlaei"
        case translation
        case transliteration
        case charTypeName = "char_type_name"
        case lemmaId
        case lemmaText
        case rootId
        case rootArabic
        case alignedEnglish
        case alignedIsImplicit
        case alignedTrailingPunctuation
        case alignmentConfidence
    }

    /// Whether this is an actual word (not a verse number marker)
    var isWord: Bool {
        charTypeName == "word"
    }

    /// A word is "absorbed" when the LLM aligner found no contiguous Saheeh
    /// span to assign to it — its meaning was fused into a neighbour's slice
    /// (e.g. فِيهِ swallowed by "about which there is no doubt" in 2:2).
    /// Render rule: hide entirely when surrounding line is English, render
    /// Arabic when any neighbour is substituted, so the line stays semantically
    /// honest at every learning stage.
    var isAbsorbed: Bool {
        guard let aligned = alignedEnglish else { return false }
        return aligned.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct WordTranslation: Codable, Sendable {
    let text: String?
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case text
        case languageName = "language_name"
    }
}

struct WordTransliteration: Codable, Sendable {
    let text: String?
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case text
        case languageName = "language_name"
    }
}

struct Translation: Codable, Identifiable, Sendable {
    let id: Int
    let resourceId: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId = "resource_id"
        case text
    }
}

struct VersesResponse: Codable, Sendable {
    let verses: [Verse]
    let pagination: Pagination?
}

struct Pagination: Codable, Sendable {
    let perPage: Int
    let currentPage: Int
    let totalPages: Int
    let totalRecords: Int

    enum CodingKeys: String, CodingKey {
        case perPage = "per_page"
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case totalRecords = "total_records"
    }
}

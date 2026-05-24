import Foundation
import GRDB

/// Fast, read-only access to bundled Quran database.
/// All queries are optimized with indexes - loads only what you need.
final class QuranDatabase: Sendable {
    static let shared: QuranDatabase = {
        do {
            return try QuranDatabase()
        } catch {
            fatalError("[QuranDatabase] Failed to open database: \(error)")
        }
    }()

    private let dbQueue: DatabaseQueue

    private init() throws {
        guard let dbPath = Bundle.main.path(forResource: "quran", ofType: "db") else {
            throw DatabaseError(message: "quran.db not found in bundle")
        }

        // Read-only configuration for bundled database
        var config = Configuration()
        config.readonly = true
        config.label = "QuranDB"

        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        dlog("[QuranDatabase] ✓ Opened database at \(dbPath)")
    }

    // MARK: - Chapters

    func fetchAllChapters() throws -> [Chapter] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name_simple, name_arabic, verses_count,
                       revelation_place, revelation_order
                FROM chapters ORDER BY id
            """)

            return rows.map { row in
                Chapter(
                    id: row["id"],
                    nameSimple: row["name_simple"],
                    nameArabic: row["name_arabic"],
                    versesCount: row["verses_count"],
                    revelationPlace: row["revelation_place"],
                    revelationOrder: row["revelation_order"],
                    pages: nil
                )
            }
        }
    }

    // MARK: - Verses

    /// Fetch a chapter's verses with words and (when `translationId` is
    /// provided AND the bundled DB has it) full per-verse translation
    /// text. The substitution view falls back to per-word translations
    /// when no verse-level translation is present, but those concatenate
    /// to title-case-with-no-punctuation garbage — bundling Saheeh full
    /// text replaces that with readable English right out of the box,
    /// without a network round-trip.
    func fetchVerses(forChapter chapterId: Int, translationId: Int? = nil) throws -> [Verse] {
        try dbQueue.read { db in
            // Fetch verses
            let verseRows = try Row.fetchAll(db, sql: """
                SELECT id, verse_number, verse_key, text_uthmani, text_imlaei
                FROM verses WHERE chapter_id = ? ORDER BY verse_number
            """, arguments: [chapterId])

            // Resource id used to select the row from word_translations_aligned.
            // Defaults to 20 (Saheeh International) since that's where the
            // alignment was run. If a future build aligns a second translation
            // we can plumb a separate parameter through.
            let alignedResourceId = translationId ?? 20

            // Fetch all words for this chapter in one query.
            // LEFT JOINs are non-blocking: morphology / alignment rows are
            // optional, so any verse that hasn't been aligned yet (the
            // alignment job is incremental) still returns valid Word rows
            // with the new fields as nil.
            let wordRows = try Row.fetchAll(db, sql: """
                SELECT w.*,
                       wta.english              AS aligned_english,
                       wta.is_implicit          AS aligned_is_implicit,
                       wta.trailing_punctuation AS aligned_trailing,
                       wta.confidence           AS aligned_confidence,
                       wr.root_id               AS root_id,
                       r.arabic_trilateral      AS root_arabic,
                       wl.lemma_id              AS lemma_id,
                       l.text                   AS lemma_text
                FROM   words w
                JOIN   verses v
                       ON v.id = w.verse_id
                LEFT JOIN word_translations_aligned wta
                       ON wta.verse_key   = v.verse_key
                      AND wta.position    = w.position
                      AND wta.resource_id = ?
                LEFT JOIN word_roots wr
                       ON wr.verse_key = v.verse_key
                      AND wr.position  = w.position
                LEFT JOIN roots r
                       ON r.id = wr.root_id
                LEFT JOIN word_lemmas wl
                       ON wl.verse_key = v.verse_key
                      AND wl.position  = w.position
                LEFT JOIN lemmas l
                       ON l.id = wl.lemma_id
                WHERE  v.chapter_id = ?
                ORDER BY v.verse_number, w.position
            """, arguments: [alignedResourceId, chapterId])

            // Group words by verse_id
            var wordsByVerse: [Int: [Word]] = [:]
            for row in wordRows {
                let verseId: Int = row["verse_id"]
                let alignedIsImplicit: Bool? = (row["aligned_is_implicit"] as Int?).map { $0 != 0 }
                let word = Word(
                    id: row["id"],
                    position: row["position"],
                    textUthmani: row["text_uthmani"],
                    textImlaei: row["text_imlaei"],
                    translation: row["translation"] != nil ? WordTranslation(
                        text: row["translation"],
                        languageName: "english"
                    ) : nil,
                    transliteration: row["transliteration"] != nil ? WordTransliteration(
                        text: row["transliteration"],
                        languageName: "english"
                    ) : nil,
                    charTypeName: row["char_type_name"],
                    lemmaId: row["lemma_id"],
                    lemmaText: row["lemma_text"],
                    rootId: row["root_id"],
                    rootArabic: row["root_arabic"],
                    alignedEnglish: row["aligned_english"],
                    alignedIsImplicit: alignedIsImplicit,
                    alignedTrailingPunctuation: row["aligned_trailing"],
                    alignmentConfidence: row["aligned_confidence"]
                )
                wordsByVerse[verseId, default: []].append(word)
            }

            // Pull verse-level translations if the caller asked for a
            // specific translation and the bundled DB has it. Returns an
            // empty dict if the verse_translations table is missing or
            // the translation id isn't bundled.
            var translationByKey: [String: String] = [:]
            if let translationId,
               let rows = try? Row.fetchAll(db, sql: """
                   SELECT vt.verse_key, vt.text
                   FROM verse_translations vt
                   JOIN verses v ON v.verse_key = vt.verse_key
                   WHERE v.chapter_id = ? AND vt.resource_id = ?
               """, arguments: [chapterId, translationId])
            {
                for row in rows {
                    translationByKey[row["verse_key"]] = row["text"]
                }
            }

            // Build verses with words + optional verse-level translation
            return verseRows.map { row in
                let verseId: Int = row["id"]
                let verseKey: String = row["verse_key"]
                // Synthesise a stable Translation row id from the verse id
                // and translation id so SwiftUI/diffing has a key, even
                // though the bundled DB has no "translation row id" of
                // its own.
                let translations: [Translation]? = translationByKey[verseKey].flatMap { text in
                    translationId.map { tid in
                        [Translation(id: verseId * 1000 + tid, resourceId: tid, text: text)]
                    }
                }
                return Verse(
                    id: verseId,
                    verseKey: verseKey,
                    verseNumber: row["verse_number"],
                    textUthmani: row["text_uthmani"],
                    textImlaei: row["text_imlaei"],
                    words: wordsByVerse[verseId],
                    translations: translations
                )
            }
        }
    }
}

// MARK: - Error

struct DatabaseError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

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

    func fetchVerses(forChapter chapterId: Int) throws -> [Verse] {
        try dbQueue.read { db in
            // Fetch verses
            let verseRows = try Row.fetchAll(db, sql: """
                SELECT id, verse_number, verse_key, text_uthmani, text_imlaei
                FROM verses WHERE chapter_id = ? ORDER BY verse_number
            """, arguments: [chapterId])

            // Fetch all words for this chapter in one query
            let wordRows = try Row.fetchAll(db, sql: """
                SELECT w.* FROM words w
                JOIN verses v ON w.verse_id = v.id
                WHERE v.chapter_id = ?
                ORDER BY v.verse_number, w.position
            """, arguments: [chapterId])

            // Group words by verse_id
            var wordsByVerse: [Int: [Word]] = [:]
            for row in wordRows {
                let verseId: Int = row["verse_id"]
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
                    charTypeName: row["char_type_name"]
                )
                wordsByVerse[verseId, default: []].append(word)
            }

            // Build verses with words
            return verseRows.map { row in
                let verseId: Int = row["id"]
                return Verse(
                    id: verseId,
                    verseKey: row["verse_key"],
                    verseNumber: row["verse_number"],
                    textUthmani: row["text_uthmani"],
                    textImlaei: row["text_imlaei"],
                    words: wordsByVerse[verseId],
                    translations: nil // We don't store verse-level translations
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

#!/usr/bin/env python3
"""Convert Quran JSON data to SQLite database for fast querying."""

import json
import sqlite3
import os

RESOURCES = "Bayan/Resources/Data"
DB_PATH = f"{RESOURCES}/quran.db"

def create_schema(conn):
    """Create database tables."""
    conn.executescript("""
        -- Chapters (114 surahs)
        CREATE TABLE IF NOT EXISTS chapters (
            id INTEGER PRIMARY KEY,
            name_simple TEXT NOT NULL,
            name_arabic TEXT NOT NULL,
            name_complex TEXT,
            verses_count INTEGER NOT NULL,
            revelation_place TEXT,
            revelation_order INTEGER,
            bismillah_pre INTEGER DEFAULT 0
        );

        -- Verses with full text
        CREATE TABLE IF NOT EXISTS verses (
            id INTEGER PRIMARY KEY,
            chapter_id INTEGER NOT NULL,
            verse_number INTEGER NOT NULL,
            verse_key TEXT NOT NULL,
            text_uthmani TEXT,
            text_imlaei TEXT,
            FOREIGN KEY (chapter_id) REFERENCES chapters(id)
        );
        CREATE INDEX IF NOT EXISTS idx_verses_chapter ON verses(chapter_id);

        -- Words (word-by-word breakdown)
        CREATE TABLE IF NOT EXISTS words (
            id INTEGER PRIMARY KEY,
            verse_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            text_uthmani TEXT,
            text_imlaei TEXT,
            translation TEXT,
            transliteration TEXT,
            char_type_name TEXT,
            audio_url TEXT,
            FOREIGN KEY (verse_id) REFERENCES verses(id)
        );
        CREATE INDEX IF NOT EXISTS idx_words_verse ON words(verse_id);
    """)
    conn.commit()

def import_chapters(conn):
    """Import chapters from JSON."""
    with open(f"{RESOURCES}/chapters.json") as f:
        chapters = json.load(f)

    for ch in chapters:
        conn.execute("""
            INSERT OR REPLACE INTO chapters
            (id, name_simple, name_arabic, name_complex, verses_count,
             revelation_place, revelation_order, bismillah_pre)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            ch["id"],
            ch["name_simple"],
            ch["name_arabic"],
            ch.get("name_complex"),
            ch["verses_count"],
            ch.get("revelation_place"),
            ch.get("revelation_order"),
            1 if ch.get("bismillah_pre") else 0
        ))
    conn.commit()
    print(f"✓ Imported {len(chapters)} chapters")

def import_verses(conn):
    """Import verses and words from JSON."""
    with open(f"{RESOURCES}/quran_verses.json") as f:
        all_verses = json.load(f)

    verse_count = 0
    word_count = 0

    for chapter_id_str, verses in all_verses.items():
        chapter_id = int(chapter_id_str)

        for verse in verses:
            # Insert verse
            conn.execute("""
                INSERT OR REPLACE INTO verses
                (id, chapter_id, verse_number, verse_key, text_uthmani, text_imlaei)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (
                verse["id"],
                chapter_id,
                verse["verse_number"],
                verse["verse_key"],
                verse.get("text_uthmani"),
                verse.get("text_imlaei")
            ))
            verse_count += 1

            # Insert words
            for word in verse.get("words", []):
                translation = word.get("translation", {})
                transliteration = word.get("transliteration", {})

                conn.execute("""
                    INSERT OR REPLACE INTO words
                    (id, verse_id, position, text_uthmani, text_imlaei,
                     translation, transliteration, char_type_name, audio_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    word["id"],
                    verse["id"],
                    word["position"],
                    word.get("text_uthmani"),
                    word.get("text_imlaei"),
                    translation.get("text") if translation else None,
                    transliteration.get("text") if transliteration else None,
                    word.get("char_type_name"),
                    word.get("audio_url")
                ))
                word_count += 1

        if chapter_id % 10 == 0:
            print(f"  Processing surah {chapter_id}...")
            conn.commit()

    conn.commit()
    print(f"✓ Imported {verse_count} verses, {word_count} words")

def optimize_db(conn):
    """Optimize database for read performance."""
    conn.execute("ANALYZE")
    conn.execute("VACUUM")
    conn.commit()
    print("✓ Optimized database")

def main():
    # Remove existing DB
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    print(f"Creating database at {DB_PATH}...")
    conn = sqlite3.connect(DB_PATH)

    try:
        create_schema(conn)
        import_chapters(conn)
        import_verses(conn)
        optimize_db(conn)

        # Print stats
        cursor = conn.execute("SELECT COUNT(*) FROM chapters")
        chapters = cursor.fetchone()[0]
        cursor = conn.execute("SELECT COUNT(*) FROM verses")
        verses = cursor.fetchone()[0]
        cursor = conn.execute("SELECT COUNT(*) FROM words")
        words = cursor.fetchone()[0]

        print(f"\n✓ Database created successfully!")
        print(f"  Chapters: {chapters}")
        print(f"  Verses: {verses}")
        print(f"  Words: {words}")

        # File size
        size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
        print(f"  Size: {size_mb:.2f} MB")

    finally:
        conn.close()

if __name__ == "__main__":
    main()

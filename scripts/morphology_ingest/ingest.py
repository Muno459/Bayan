#!/usr/bin/env python3
"""
ingest.py — merge QUL's word-root, word-lemma, word-stem SQLite dumps into
ayyat's bundled quran.db as 6 new tables (3 dimension, 3 mapping).

Source files (from qul.tarteel.ai):
    word-root.db    roots(id, arabic_trilateral, english_trilateral,
                          words_count, uniq_words_count)
                    root_words(root_id, word_location)
    word-lemma.db   lemmas(id, text, text_clean, words_count, uniq_words_count)
                    lemma_words(lemma_id, word_location)
    word-stem.db    stems(id, text, text_clean, words_count, uniq_words_count)
                    stem_words(stem_id, word_location)

`word_location` is "surah:ayah:position" — we split it into
`(verse_key="surah:ayah", position=int)` to match ayyat's `words` table.

QUL's lemma/stem dumps leave `words_count` and `uniq_words_count` empty;
we recompute them here.

Safe to re-run: drops + recreates the morphology tables in a single
transaction, after a one-time `quran.db.pre-morphology-backup` snapshot.
"""
from __future__ import annotations

import re
import shutil
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TARGET_DB = HERE.parent.parent / "ayyat" / "Resources" / "Data" / "quran.db"
ROOT_SRC = HERE / "word-root.db"
LEMMA_SRC = HERE / "word-lemma.db"
STEM_SRC = HERE / "word-stem.db"
BACKUP = TARGET_DB.with_suffix(".db.pre-morphology-backup")

# Tables we own. Dropped+recreated on every run, so the operation is
# fully idempotent.
MANAGED_TABLES = (
    "word_roots", "roots",
    "word_lemmas", "lemmas",
    "word_stems", "stems",
)


def normalize_arabic_trilateral(s: str) -> str:
    """QUL has inconsistent inter-letter spacing; collapse to single spaces."""
    return re.sub(r"\s+", " ", s).strip()


def split_location(loc: str) -> tuple[str, int]:
    """`'1:1:1'` → `('1:1', 1)`."""
    s, a, p = loc.split(":")
    return f"{s}:{a}", int(p)


def create_tables(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        DROP TABLE IF EXISTS word_roots;
        DROP TABLE IF EXISTS roots;
        DROP TABLE IF EXISTS word_lemmas;
        DROP TABLE IF EXISTS lemmas;
        DROP TABLE IF EXISTS word_stems;
        DROP TABLE IF EXISTS stems;

        CREATE TABLE roots (
            id                 INTEGER PRIMARY KEY,
            arabic_trilateral  TEXT    NOT NULL,
            english_trilateral TEXT    NOT NULL,
            words_count        INTEGER NOT NULL,
            uniq_words_count   INTEGER NOT NULL
        );
        CREATE TABLE word_roots (
            verse_key TEXT    NOT NULL,
            position  INTEGER NOT NULL,
            root_id   INTEGER NOT NULL,
            PRIMARY KEY (verse_key, position)
        );
        CREATE INDEX idx_word_roots_root ON word_roots(root_id);

        CREATE TABLE lemmas (
            id               INTEGER PRIMARY KEY,
            text             TEXT    NOT NULL,
            text_clean       TEXT    NOT NULL,
            words_count      INTEGER NOT NULL,
            uniq_words_count INTEGER NOT NULL
        );
        CREATE TABLE word_lemmas (
            verse_key TEXT    NOT NULL,
            position  INTEGER NOT NULL,
            lemma_id  INTEGER NOT NULL,
            PRIMARY KEY (verse_key, position)
        );
        CREATE INDEX idx_word_lemmas_lemma ON word_lemmas(lemma_id);

        CREATE TABLE stems (
            id               INTEGER PRIMARY KEY,
            text             TEXT    NOT NULL,
            text_clean       TEXT    NOT NULL,
            words_count      INTEGER NOT NULL,
            uniq_words_count INTEGER NOT NULL
        );
        CREATE TABLE word_stems (
            verse_key TEXT    NOT NULL,
            position  INTEGER NOT NULL,
            stem_id   INTEGER NOT NULL,
            PRIMARY KEY (verse_key, position)
        );
        CREATE INDEX idx_word_stems_stem ON word_stems(stem_id);
    """)


def ingest_morphology(
    target: sqlite3.Connection,
    source_path: Path,
    *,
    src_dim_table: str,
    src_map_table: str,
    src_map_fk: str,         # "root_id" / "lemma_id" / "stem_id"
    dst_dim_table: str,
    dst_map_table: str,
    dst_map_fk: str,
    text_columns: tuple[str, ...],   # ("arabic_trilateral","english_trilateral") or ("text","text_clean")
    compute_counts: bool,
) -> tuple[int, int]:
    src = sqlite3.connect(source_path)
    src.row_factory = sqlite3.Row
    try:
        dim_rows = list(src.execute(f"SELECT * FROM {src_dim_table}").fetchall())
        map_rows = list(src.execute(f"SELECT * FROM {src_map_table}").fetchall())

        # Build computed counts if QUL didn't provide them.
        computed_uses: dict[int, int] = {}
        computed_uniq: dict[int, set[str]] = {}
        if compute_counts:
            for m in map_rows:
                fk = m[src_map_fk]
                computed_uses[fk] = computed_uses.get(fk, 0) + 1
                # uniq_words_count semantically = number of distinct surface
                # forms. We don't have the form here, so use the location set
                # as a proxy (QUL does the same).
                computed_uniq.setdefault(fk, set()).add(m["word_location"])

        # Dimension table.
        dim_inserts: list[tuple] = []
        for r in dim_rows:
            row_id = r["id"]
            if "arabic_trilateral" in r.keys():
                text_a = normalize_arabic_trilateral(r["arabic_trilateral"] or "")
                text_b = (r["english_trilateral"] or "").strip()
            else:
                text_a = (r["text"] or "").strip()
                text_b = (r["text_clean"] or "").strip()

            words_count = (
                computed_uses.get(row_id, 0) if compute_counts
                else int(r["words_count"] or 0)
            )
            uniq_words_count = (
                len(computed_uniq.get(row_id, set())) if compute_counts
                else int(r["uniq_words_count"] or 0)
            )

            dim_inserts.append((row_id, text_a, text_b, words_count, uniq_words_count))

        target.executemany(
            f"INSERT INTO {dst_dim_table} (id, {text_columns[0]}, {text_columns[1]}, "
            f"words_count, uniq_words_count) VALUES (?, ?, ?, ?, ?)",
            dim_inserts,
        )

        # Mapping table.
        map_inserts = []
        skipped_dupes = 0
        seen: set[tuple[str, int]] = set()
        for m in map_rows:
            verse_key, position = split_location(m["word_location"])
            key = (verse_key, position)
            if key in seen:
                # QUL very rarely has duplicate location rows; keep first.
                skipped_dupes += 1
                continue
            seen.add(key)
            map_inserts.append((verse_key, position, m[src_map_fk]))

        target.executemany(
            f"INSERT INTO {dst_map_table} (verse_key, position, {dst_map_fk}) "
            f"VALUES (?, ?, ?)",
            map_inserts,
        )

        if skipped_dupes:
            print(f"  note: {skipped_dupes} duplicate location row(s) skipped")

        return len(dim_inserts), len(map_inserts)
    finally:
        src.close()


def verify(target: sqlite3.Connection) -> None:
    print("\n=== verification ===")
    checks = [
        ("roots",       1642),
        ("word_roots",  50298),
        ("lemmas",      4817),
        ("word_lemmas", 72510),
        ("stems",       12113),
        ("word_stems",  77427),
    ]
    for table, expected_min in checks:
        n = target.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        ok = "OK " if n >= expected_min - 5 else "FAIL"
        print(f"  {ok}  {table}: {n} (expected ~{expected_min})")

    # Orphan check: every word_xxx.root_id must exist in roots, etc.
    orphans = target.execute("""
        SELECT
          (SELECT COUNT(*) FROM word_roots wr   LEFT JOIN roots   r ON r.id=wr.root_id   WHERE r.id IS NULL),
          (SELECT COUNT(*) FROM word_lemmas wl  LEFT JOIN lemmas  l ON l.id=wl.lemma_id  WHERE l.id IS NULL),
          (SELECT COUNT(*) FROM word_stems ws   LEFT JOIN stems   s ON s.id=ws.stem_id   WHERE s.id IS NULL)
    """).fetchone()
    print(f"  orphans: word_roots={orphans[0]} word_lemmas={orphans[1]} word_stems={orphans[2]}")

    # Spot-check Surah 1: ٱللَّهِ at 1:1:2 should resolve to root ا ل ه
    row = target.execute("""
        SELECT r.arabic_trilateral, r.english_trilateral
        FROM word_roots wr JOIN roots r ON r.id=wr.root_id
        WHERE wr.verse_key='1:1' AND wr.position=2
    """).fetchone()
    print(f"  spot 1:1 pos 2 root: {row!r}  (expect ('ا ل ه','Alh'))")

    row = target.execute("""
        SELECT l.text FROM word_lemmas wl JOIN lemmas l ON l.id=wl.lemma_id
        WHERE wl.verse_key='1:1' AND wl.position=2
    """).fetchone()
    print(f"  spot 1:1 pos 2 lemma: {row!r}  (expect ('اللَّه',))")


def main() -> int:
    if not TARGET_DB.exists():
        print(f"FATAL: target db not found at {TARGET_DB}", file=sys.stderr)
        return 2
    for src in (ROOT_SRC, LEMMA_SRC, STEM_SRC):
        if not src.exists():
            print(f"FATAL: source db missing: {src}", file=sys.stderr)
            return 2

    if not BACKUP.exists():
        print(f"backing up: {TARGET_DB.name} -> {BACKUP.name}")
        shutil.copy2(TARGET_DB, BACKUP)
    else:
        print(f"backup already exists at {BACKUP.name} (re-running safely)")

    target = sqlite3.connect(TARGET_DB)
    target.execute("PRAGMA foreign_keys = OFF")
    try:
        with target:
            print("creating morphology tables...")
            create_tables(target)

            print("ingesting roots...")
            n_dim, n_map = ingest_morphology(
                target, ROOT_SRC,
                src_dim_table="roots", src_map_table="root_words", src_map_fk="root_id",
                dst_dim_table="roots", dst_map_table="word_roots", dst_map_fk="root_id",
                text_columns=("arabic_trilateral", "english_trilateral"),
                compute_counts=False,
            )
            print(f"  inserted: {n_dim} roots, {n_map} word_roots")

            print("ingesting lemmas (computing counts)...")
            n_dim, n_map = ingest_morphology(
                target, LEMMA_SRC,
                src_dim_table="lemmas", src_map_table="lemma_words", src_map_fk="lemma_id",
                dst_dim_table="lemmas", dst_map_table="word_lemmas", dst_map_fk="lemma_id",
                text_columns=("text", "text_clean"),
                compute_counts=True,
            )
            print(f"  inserted: {n_dim} lemmas, {n_map} word_lemmas")

            print("ingesting stems (computing counts)...")
            n_dim, n_map = ingest_morphology(
                target, STEM_SRC,
                src_dim_table="stems", src_map_table="stem_words", src_map_fk="stem_id",
                dst_dim_table="stems", dst_map_table="word_stems", dst_map_fk="stem_id",
                text_columns=("text", "text_clean"),
                compute_counts=True,
            )
            print(f"  inserted: {n_dim} stems, {n_map} word_stems")

        verify(target)
    finally:
        target.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())

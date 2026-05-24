#!/usr/bin/env python3
"""
Fetch Saheeh International (translation id 20) for every verse and
insert into the bundled quran.db so the reader has proper full-sentence
English with punctuation offline. Replaces the per-word concatenation
fallback that gave the user "That (is) the book no doubt in it…" with
title-case, no-punctuation output.

Usage:
    python3 scripts/bundle_saheeh_translation.py

Idempotent — safe to re-run. Drops and recreates the verse_translations
table each time.
"""
import json
import re
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "ayyat" / "Resources" / "Data" / "quran.db"
TRANSLATION_ID = 20  # Saheeh International on api.quran.com v4

API_BASE = "https://api.quran.com/api/v4"


def fetch_chapter(chapter: int) -> list[dict]:
    # api.quran.com rate-limits the default Python UA aggressively (403
    # after a handful of requests). A normal-looking UA + slower cadence
    # avoids the throttle.
    url = f"{API_BASE}/verses/by_chapter/{chapter}?translations={TRANSLATION_ID}&per_page=300"
    req = urllib.request.Request(url, headers={
        "User-Agent": "ayyat-bundler/1.0 (+https://ayyat.net)",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    return data.get("verses", [])


def strip_html(text: str) -> str:
    # Drop QF's <sup> footnote markers and any other inline HTML so the
    # text we store is clean reader-ready content.
    text = re.sub(r"<sup[^>]*>.*?</sup>", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.strip()


def main() -> int:
    if not DB_PATH.exists():
        print(f"DB not found at {DB_PATH}", file=sys.stderr)
        return 1

    print(f"Connecting to {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("DROP TABLE IF EXISTS verse_translations")
    cur.execute(
        """
        CREATE TABLE verse_translations (
            verse_key TEXT NOT NULL,
            resource_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (verse_key, resource_id)
        )
        """
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_vt_resource ON verse_translations(resource_id)")

    total = 0
    for chapter in range(1, 115):
        attempts = 0
        verses = []
        while attempts < 5:
            try:
                verses = fetch_chapter(chapter)
                break
            except Exception as e:
                attempts += 1
                # Exponential backoff so we ease off when throttled.
                wait = 2 ** attempts
                print(f"  retry chapter {chapter} in {wait}s ({e})")
                time.sleep(wait)
        if not verses:
            print(f"  ✗ chapter {chapter}: no verses")
            continue

        rows = []
        for v in verses:
            vk = v.get("verse_key")
            t_list = v.get("translations") or []
            if not vk or not t_list:
                continue
            text = strip_html(t_list[0].get("text", ""))
            if text:
                rows.append((vk, TRANSLATION_ID, text))

        cur.executemany(
            "INSERT OR REPLACE INTO verse_translations (verse_key, resource_id, text) VALUES (?, ?, ?)",
            rows,
        )
        total += len(rows)
        if chapter % 10 == 0 or chapter == 114:
            print(f"  chapter {chapter:3d} done — {len(rows)} rows, {total} total")
        # Gentle on the API — 350 ms keeps us well under quran.com's
        # public rate limit (anecdotally ~10 RPS).
        time.sleep(0.35)

    conn.commit()

    # Sanity check
    cur.execute("SELECT verse_key, text FROM verse_translations WHERE verse_key IN ('1:2','2:2','2:255') ORDER BY verse_key")
    print()
    print("Spot-check:")
    for vk, t in cur.fetchall():
        print(f"  {vk}: {t[:100]}")

    cur.execute("SELECT COUNT(*) FROM verse_translations WHERE resource_id=?", (TRANSLATION_ID,))
    print(f"\n✓ {cur.fetchone()[0]} verses written")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

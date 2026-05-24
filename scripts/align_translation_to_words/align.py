#!/usr/bin/env python3
"""
align.py — bind a verse-level Quran translation (e.g. Saheeh International)
to per-word Arabic, using an LLM with a literal word-by-word (WBW)
semantic anchor and writing the alignment to a SQLite database.

Pipeline per verse:

  SYSTEM (cached): role, output schema, hard rules, 3 few-shot exemplars
  USER:
    verse_key
    arabic words: position + textUthmani + WBW literal gloss
    saheeh sentence

The WBW gloss is a sanity anchor — it tells the LLM what each Arabic
word literally means so it doesn't have to infer it from training data.
Combined with the Saheeh sentence as the target, the alignment becomes
deterministic.

Output (per word):
    position, arabic, wbw_anchor, english, is_implicit,
    trailing_punctuation, confidence (high|medium|low), notes

See ./README.md for design rationale.
"""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import logging
import os
import re
import signal
import sqlite3
import sys
import time
import unicodedata
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable, Sequence

import httpx


# ─── Configuration ──────────────────────────────────────────────────────────

DEFAULT_API_BASE = "https://router.darra.ai/v1"
DEFAULT_MODEL = "cc/claude-opus-4-7"
DEFAULT_WORKERS = 8
DEFAULT_RATE_LIMIT_MS = 250
DEFAULT_TIMEOUT_S = 180
MAX_RETRIES = 5
LOG = logging.getLogger("align")


# ─── Data types ─────────────────────────────────────────────────────────────


@dataclasses.dataclass(frozen=True)
class ArabicWord:
    position: int       # 1-indexed
    text: str           # textUthmani
    wbw_anchor: str     # literal word-by-word gloss (semantic anchor)


@dataclasses.dataclass(frozen=True)
class VerseJob:
    verse_key: str
    chapter_id: int
    verse_number: int
    saheeh: str
    words: tuple[ArabicWord, ...]


@dataclasses.dataclass
class AlignedWord:
    position: int
    arabic: str
    wbw_anchor: str
    english: str
    is_implicit: bool
    trailing_punctuation: str | None
    confidence: str        # "high" | "medium" | "low"
    notes: str | None
    is_absorbed: bool = False   # true when english is the WBW fallback (Saheeh had no slice)


# Compact-schema → canonical-schema mappings.
_CONF_EXPAND = {"h": "high", "m": "medium", "l": "low"}


# ─── Database I/O ───────────────────────────────────────────────────────────


SCHEMA = """
CREATE TABLE IF NOT EXISTS word_translations_aligned (
    verse_key            TEXT    NOT NULL,
    position             INTEGER NOT NULL,
    resource_id          INTEGER NOT NULL,
    english              TEXT    NOT NULL,
    is_implicit          INTEGER NOT NULL DEFAULT 0,
    trailing_punctuation TEXT,
    notes                TEXT,
    model_version        TEXT    NOT NULL,
    PRIMARY KEY (verse_key, position, resource_id)
);

CREATE INDEX IF NOT EXISTS idx_wta_verse
    ON word_translations_aligned (verse_key, resource_id);
"""

# Non-destructive migration: add new columns if they don't exist.
# SQLite has no `ADD COLUMN IF NOT EXISTS` so we probe `PRAGMA table_info`.
EXTRA_COLUMNS: list[tuple[str, str]] = [
    ("wbw_anchor", "TEXT"),
    ("confidence", "TEXT"),
    ("is_absorbed", "INTEGER NOT NULL DEFAULT 0"),
]


@contextmanager
def open_db(path: Path):
    # `check_same_thread=False` is required because the connection is
    # used from async workers; writes are serialised by an asyncio Lock.
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try:
        conn.executescript(SCHEMA)
        existing = {r["name"] for r in conn.execute(
            "PRAGMA table_info(word_translations_aligned)"
        )}
        for col, typ in EXTRA_COLUMNS:
            if col not in existing:
                conn.execute(
                    f"ALTER TABLE word_translations_aligned ADD COLUMN {col} {typ}"
                )
        conn.commit()
        yield conn
    finally:
        conn.close()


def fetch_verse_jobs(
    conn: sqlite3.Connection,
    resource_id: int,
    chapter: int | None,
    only_missing: bool,
) -> list[VerseJob]:
    sql = """
        SELECT v.id            AS verse_id,
               v.chapter_id    AS chapter_id,
               v.verse_number  AS verse_number,
               v.verse_key     AS verse_key,
               vt.text         AS saheeh
        FROM   verses v
        JOIN   verse_translations vt ON vt.verse_key = v.verse_key
        WHERE  vt.resource_id = ?
    """
    args: list[Any] = [resource_id]
    if chapter is not None:
        sql += " AND v.chapter_id = ?"
        args.append(chapter)
    sql += " ORDER BY v.chapter_id, v.verse_number"

    verse_rows = list(conn.execute(sql, args).fetchall())

    already: set[str] = set()
    if only_missing:
        already = {
            row["verse_key"]
            for row in conn.execute(
                "SELECT DISTINCT verse_key FROM word_translations_aligned WHERE resource_id = ?",
                (resource_id,),
            ).fetchall()
        }

    jobs: list[VerseJob] = []
    for row in verse_rows:
        if row["verse_key"] in already:
            continue
        words = [
            ArabicWord(
                position=w["position"],
                text=w["text_uthmani"],
                wbw_anchor=(w["translation"] or "").strip(),
            )
            for w in conn.execute(
                """
                SELECT position, text_uthmani, translation
                FROM   words
                WHERE  verse_id = ?
                AND    char_type_name = 'word'
                ORDER BY position
                """,
                (row["verse_id"],),
            ).fetchall()
            if w["text_uthmani"]
        ]
        if not words:
            continue
        jobs.append(
            VerseJob(
                verse_key=row["verse_key"],
                chapter_id=row["chapter_id"],
                verse_number=row["verse_number"],
                saheeh=row["saheeh"],
                words=tuple(words),
            )
        )
    return jobs


def write_aligned(
    conn: sqlite3.Connection,
    verse_key: str,
    resource_id: int,
    aligned: Sequence[AlignedWord],
    model_version: str,
) -> None:
    conn.execute(
        "DELETE FROM word_translations_aligned WHERE verse_key=? AND resource_id=?",
        (verse_key, resource_id),
    )
    conn.executemany(
        """
        INSERT INTO word_translations_aligned
            (verse_key, position, resource_id, english, is_implicit,
             trailing_punctuation, notes, model_version,
             wbw_anchor, confidence, is_absorbed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                verse_key,
                a.position,
                resource_id,
                a.english,
                1 if a.is_implicit else 0,
                a.trailing_punctuation,
                a.notes,
                model_version,
                a.wbw_anchor,
                a.confidence,
                1 if a.is_absorbed else 0,
            )
            for a in aligned
        ],
    )
    conn.commit()


# ─── LLM prompt + response parsing ──────────────────────────────────────────


SYSTEM_PROMPT = """\
You are an expert in Quranic Arabic exegesis and English Quran translation methodology. Your task is to align Saheeh International English translation to per-word Arabic for use in a progressive language-learning iOS app, where each Arabic word's English "owner span" gets substituted with the Arabic word as the learner progresses.

INPUT shape (per verse):
- A list of Arabic words in recitation order, each with: (a) its position (1-indexed), (b) the verbatim Uthmani spelling, (c) a literal word-by-word gloss from Quran Foundation that tells you what the word LITERALLY means.
- The full Saheeh International English sentence for the verse.

OUTPUT shape: STRICT JSON ARRAY, one entry per input Arabic word, **in the same order as the input** (array index N corresponds to input position N+1). Each entry is a COMPACT JSON OBJECT with single-letter keys:

    {
        "e": <string, REQUIRED, NON-EMPTY — the English for this Arabic word>,
        "p": <string or null, OPTIONAL — trailing Saheeh punctuation: one of "," "." ";" ":" "?" "!" "—" "(" ")" — omit or null if none>,
        "c": <string, OPTIONAL — "h" | "m" | "l", default "h" if omitted>,
        "i": <bool, OPTIONAL — true if "e" is a translator-supplied bracketed clarification like "[All]" or "(is)" with no direct Arabic counterpart, default false>,
        "a": <bool, OPTIONAL — true if Saheeh has NO contiguous slice for this Arabic word and you fell back to the literal gloss; default false>,
        "n": <string, OPTIONAL — short linguistic note, ONLY include when "c" is "m" or "l">
    }

HARD RULES:

1. Output ONE entry per input Arabic word. Same count, same order. Array index → input position (idx 0 = position 1, idx 1 = position 2, …).

2. The "e" field is ALWAYS NON-EMPTY. Two paths to populate it:
   a) **Default path**: "e" is a CONTIGUOUS slice of the Saheeh sentence — word-for-word from Saheeh — that this Arabic word owns. Never invent, paraphrase, or pluralise. Copy contiguous Saheeh tokens verbatim (preserving Saheeh's spelling like "Allāh" with macron, bracketed clarifications like "[All]", etc.).
   b) **Absorbed fallback**: if Saheeh has NO contiguous slice for this Arabic word because Saheeh fused its meaning into a neighbour's phrase (typical for prepositions, particles, fused copulas), use the input literal gloss verbatim as "e" AND set "a": true. Do not invent; use the input literal exactly.

3. Translator clarifications in square brackets [like this] or parentheses (like this) that have no direct Arabic counterpart are assigned to the nearest preceding Arabic word and included inside its "e" slice. They are NOT "i: true" — set "i": true ONLY when the entire "e" is a bracketed clarification on its own (rare). Bracketed clarifications attached to a real word slice keep "i": false.

4. Punctuation belongs to the entry whose "e" slice it follows. Do not duplicate punctuation across entries.

5. Concatenating every entry's "e" (joined by spaces) + "p" should reproduce the Saheeh sentence for non-absorbed entries (allowing whitespace + diacritic differences). Absorbed entries inject the literal gloss inline; they're skipped from this reconstruction check.

6. Use the literal gloss as a semantic anchor: an Arabic word's "e" slice should preserve the core meaning visible in the literal. If your alignment fundamentally disagrees with the literal gloss, mark "c":"l" and explain in "n".

7. Return ONLY the JSON array. No prose, no markdown fences, no commentary.

FEW-SHOT EXAMPLES (study the alignment patterns):

EXAMPLE 1 — simple verse, all words map directly.
Input:
verse_key: 1:1
arabic:
  [1] بِسْمِ        literal: "In (the) name"
  [2] ٱللَّهِ        literal: "(of) Allah"
  [3] ٱلرَّحْمَـٰنِ  literal: "the Most Gracious"
  [4] ٱلرَّحِيمِ    literal: "the Most Merciful"
saheeh: "In the name of Allāh, the Entirely Merciful, the Especially Merciful."

Output:
[
  {"e":"In the name of"},
  {"e":"Allāh","p":","},
  {"e":"the Entirely Merciful","p":","},
  {"e":"the Especially Merciful","p":"."}
]

EXAMPLE 2 — verse with bracketed translator clarification preserved inside slice.
Input:
verse_key: 1:2
arabic:
  [1] ٱلْحَمْدُ      literal: "All praises and thanks"
  [2] لِلَّهِ        literal: "(be) to Allah"
  [3] رَبِّ          literal: "the Lord"
  [4] ٱلْعَـٰلَمِينَ  literal: "of the universe"
saheeh: "[All] praise is [due] to Allāh, Lord of the worlds —"

Output:
[
  {"e":"[All] praise is [due]"},
  {"e":"to Allāh","p":","},
  {"e":"Lord of"},
  {"e":"the worlds","p":"—"}
]

EXAMPLE 3 — verse with Saheeh-absorbed word (no contiguous English slice).
Input:
verse_key: 2:2
arabic:
  [1] ذَٰلِكَ          literal: "That"
  [2] ٱلْكِتَـٰبُ      literal: "(is) the Book"
  [3] لَا              literal: "no"
  [4] رَيْبَ            literal: "doubt"
  [5] فِيهِ            literal: "in it"
  [6] هُدًۭى          literal: "a Guidance"
  [7] لِّلْمُتَّقِينَ  literal: "for the God-conscious"
saheeh: "This is the Book about which there is no doubt, a guidance for those conscious of Allāh"

Output:
[
  {"e":"This","c":"h","n":"demonstrative; Saheeh uses 'This' though literal is 'That'"},
  {"e":"is the Book"},
  {"e":"about which there is no","c":"m","n":"negation particle; Saheeh expands with 'about which there is' for English flow"},
  {"e":"doubt","p":","},
  {"e":"in it","a":true,"c":"l","n":"absorbed: Saheeh fused into 'about which' on idx 2; using literal gloss"},
  {"e":"a guidance"},
  {"e":"for those conscious of Allāh"}
]

Note the absorbed entry on idx 4 (position 5, فِيهِ): Saheeh has no slice for it, so "e" gets the literal "in it" and "a": true. The downstream renderer treats absorbed entries as fallback English — every Arabic word always has a usable English.

Now produce the JSON for the input below.
"""


def build_user_prompt(job: VerseJob) -> str:
    word_lines = "\n".join(
        f"  [{w.position}] {w.text}  literal: {w.wbw_anchor!r}"
        for w in job.words
    )
    return (
        f"verse_key: {job.verse_key}\n"
        f"arabic:\n{word_lines}\n"
        f"saheeh: {job.saheeh!r}\n"
    )


def _extract_json_array(text: str) -> str:
    """Find the first balanced top-level JSON array in `text`."""
    start = text.find("[")
    if start == -1:
        raise ValueError("No JSON array found in model response")
    in_string = False
    escape = False
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if escape:
            escape = False
            continue
        if in_string:
            if ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    raise ValueError("Unbalanced JSON array in model response")


def parse_llm_response(content: str, job: "VerseJob") -> list[AlignedWord]:
    """Parse the compact-schema response and reconcile against the input verse.

    The model emits one tiny dict per Arabic word, in input order. We:
    - default missing optional keys ("p":null, "c":"h", "i":false, "a":false)
    - reattach the verbatim Arabic + wbw_anchor from input (we never asked
      the model to echo them, but the DB schema preserves them for audit)
    - if the model emitted an empty/missing "e" despite the prompt, treat
      it as absorbed and substitute the input WBW gloss (so the DB never
      stores an empty english)
    """
    content = content.strip()
    if content.startswith("```"):
        content = content.strip("`").lstrip("json").strip()
    arr = json.loads(_extract_json_array(content))
    if not isinstance(arr, list):
        raise ValueError("LLM returned non-array JSON")

    # Tolerate one extra trailing entry — Opus occasionally appends a
    # phantom row for sentence-final punctuation on certain verses
    # (deterministically reproducible on 5:41, 20:98, 26:167, 45:33).
    # Dropping the tail is safe because the Arabic position iteration
    # is anchored to job.words, so the extra entry never gets used.
    if len(arr) == len(job.words) + 1:
        arr = arr[:-1]
    elif len(arr) != len(job.words):
        raise ValueError(
            f"entry count {len(arr)} doesn't match input word count {len(job.words)}"
        )

    out: list[AlignedWord] = []
    for idx, item in enumerate(arr):
        if not isinstance(item, dict):
            raise ValueError(f"Entry {idx} is not an object: {item!r}")

        word = job.words[idx]   # source of truth for position/arabic/wbw

        conf_raw = str(item.get("c", "h")).lower()
        conf = _CONF_EXPAND.get(conf_raw, conf_raw if conf_raw in ("high", "medium", "low") else "high")
        is_absorbed = bool(item.get("a", False))
        english = str(item.get("e", "") or "").strip()

        # Defensive: model violated the "always non-empty e" rule.
        # Substitute the input WBW gloss; mark absorbed so it's still
        # recoverable downstream.
        if not english:
            english = word.wbw_anchor or ""
            is_absorbed = True

        out.append(
            AlignedWord(
                position=word.position,
                arabic=word.text,
                wbw_anchor=word.wbw_anchor,
                english=english,
                is_implicit=bool(item.get("i", False)),
                trailing_punctuation=(item.get("p") or None),
                confidence=conf,
                notes=(item.get("n") or None),
                is_absorbed=is_absorbed,
            )
        )
    return out


# ─── Validation ─────────────────────────────────────────────────────────────


def _norm_for_compare(s: str) -> str:
    s = s.lower()
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"[ʽʼ'']", "'", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()


# U+06D6..U+06ED are Qur'anic recitation / pause marks ("small high"
# annotations like ۖ ۗ ۘ ۙ ۚ ۛ ۜ ۝ ۞ ۟ ۠ ۡ ۢ ۣ ۤ ۥ ۦ ۧ ۨ ۩ ۪ ۫ ۬ ۭ).
# They are typesetting hints, not part of the word — the LLM may keep
# or drop them, so strip them for the byte-level equality check.
_RECITATION_MARKS = "".join(chr(c) for c in range(0x06D6, 0x06ED + 1))
_RECITATION_TABLE = {ord(c): None for c in _RECITATION_MARKS}


def _strip_arabic_marks(text: str) -> str:
    return unicodedata.normalize("NFC", text).translate(_RECITATION_TABLE).strip()


def validate(job: VerseJob, aligned: list[AlignedWord]) -> list[str]:
    issues: list[str] = []

    if len(aligned) != len(job.words):
        issues.append(
            f"count mismatch: input={len(job.words)} aligned={len(aligned)}"
        )

    input_positions = [w.position for w in job.words]
    out_positions = [a.position for a in aligned]
    if input_positions != out_positions:
        issues.append(
            f"position drift: input={input_positions} aligned={out_positions}"
        )

    for w, a in zip(job.words, aligned):
        if _strip_arabic_marks(w.text) != _strip_arabic_marks(a.arabic):
            issues.append(
                f"position {w.position}: arabic mismatch "
                f"input={w.text!r} aligned={a.arabic!r}"
            )

    # New compact schema invariant: english is never empty. The parser
    # substitutes WBW + sets is_absorbed=True if the model violated the
    # rule, so any empty here is a parser bug — caught loudly.
    for a in aligned:
        if not a.english.strip():
            issues.append(f"position {a.position}: empty english (invariant violation)")

    # Reconstruction check — only NON-absorbed entries should match
    # Saheeh, since absorbed entries inject the literal gloss inline
    # (which won't appear verbatim in the Saheeh sentence).
    reconstructed = " ".join(
        f"{a.english}{a.trailing_punctuation or ''}"
        for a in aligned
        if a.english.strip() and not a.is_absorbed
    )
    rn = _norm_for_compare(reconstructed)
    sn = _norm_for_compare(job.saheeh)
    # Length sanity check — very lenient. Saheeh has whole phrases that
    # the alignment legitimately absorbs ("about which there is" eats a
    # preposition+pronoun), and on short verses those add up to large
    # percentages without being errors. Threshold of 50% only catches
    # egregious LLM mishaps; we still log the delta so a human can spot
    # outliers if they want.
    if rn and sn:
        delta = abs(len(rn) - len(sn)) / max(len(sn), 1)
        if delta > 0.50:
            issues.append(
                f"reconstructed length differs by {delta:.1%} "
                f"(got={len(rn)} expected={len(sn)})"
            )

    return issues


# ─── LLM client ─────────────────────────────────────────────────────────────


class LLMClient:
    def __init__(
        self,
        api_key: str,
        api_base: str,
        model: str,
        timeout_s: int,
        rate_limit_ms: int,
    ) -> None:
        self.api_key = api_key
        self.api_base = api_base.rstrip("/")
        self.model = model
        self.rate_limit_s = rate_limit_ms / 1000
        self._last_call_at: float = 0.0
        self._lock = asyncio.Lock()
        self.client = httpx.AsyncClient(timeout=timeout_s, http2=True)

    async def aclose(self) -> None:
        await self.client.aclose()

    async def complete(self, system: str, user: str) -> str:
        async with self._lock:
            wait = self.rate_limit_s - (time.monotonic() - self._last_call_at)
            if wait > 0:
                await asyncio.sleep(wait)
            self._last_call_at = time.monotonic()

        last_err: Exception | None = None
        for attempt in range(MAX_RETRIES):
            try:
                body: dict[str, Any] = {
                    "model": self.model,
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                    "stream": False,
                    # Bumped from the router default (~4096) because the
                    # longest verses (e.g. 2:282 ~290 words) overflow
                    # mid-array and we get unbalanced-JSON parse errors.
                    "max_tokens": 8192,
                }
                # claude-opus-4-7 deprecates `temperature`; keep determinism
                # via the seed-equivalent default for that model, otherwise
                # pin temperature=0 for the older models.
                if "opus-4-7" not in self.model:
                    body["temperature"] = 0.0
                resp = await self.client.post(
                    f"{self.api_base}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Content-Type": "application/json",
                    },
                    json=body,
                )
                if resp.status_code == 429:
                    backoff = 2 ** attempt
                    LOG.warning(
                        "rate-limited, sleeping %ds before retry %d",
                        backoff, attempt + 1
                    )
                    await asyncio.sleep(backoff)
                    continue
                resp.raise_for_status()
                payload = resp.json()
                return payload["choices"][0]["message"]["content"]
            except Exception as e:
                last_err = e
                backoff = min(2 ** attempt, 30)
                LOG.warning(
                    "request failed (attempt %d/%d): %s; retrying in %ds",
                    attempt + 1, MAX_RETRIES, e, backoff,
                )
                await asyncio.sleep(backoff)
        raise RuntimeError(f"LLM call failed after {MAX_RETRIES} attempts") from last_err


# ─── Worker ─────────────────────────────────────────────────────────────────


async def process_verse(
    client: LLMClient,
    job: VerseJob,
    conn: sqlite3.Connection,
    db_lock: asyncio.Lock,
    resource_id: int,
    dry_run: bool,
    progress: dict,
) -> str:
    user = build_user_prompt(job)
    try:
        raw = await client.complete(SYSTEM_PROMPT, user)
        aligned = parse_llm_response(raw, job)
    except Exception as e:
        LOG.error("%s: parse error: %s", job.verse_key, e)
        return "error"

    issues = validate(job, aligned)
    if issues:
        LOG.warning("%s: validation issues — %s", job.verse_key, "; ".join(issues))
        return "validation"

    low_conf = sum(1 for a in aligned if a.confidence == "low")
    if low_conf > 0:
        LOG.info("%s: %d/%d low-confidence", job.verse_key, low_conf, len(aligned))

    if dry_run:
        LOG.info("%s: dry-run, %d entries", job.verse_key, len(aligned))
        for a in aligned:
            LOG.info(
                "  pos=%-2d %s  →  %s%s  [conf=%s%s]",
                a.position,
                a.arabic,
                a.english or "(absorbed)",
                a.trailing_punctuation or "",
                a.confidence,
                " · implicit" if a.is_implicit else "",
            )
    else:
        async with db_lock:
            write_aligned(conn, job.verse_key, resource_id, aligned, client.model)

    progress["done"] += 1
    if progress["done"] % 25 == 0 or progress["done"] == progress["total"]:
        elapsed = time.monotonic() - progress["start"]
        rate = progress["done"] / max(elapsed, 0.01)
        eta = (progress["total"] - progress["done"]) / max(rate, 0.01)
        LOG.info(
            "progress: %d/%d (%.2f/s, eta %dm%ds)",
            progress["done"], progress["total"], rate,
            int(eta // 60), int(eta % 60),
        )

    return "ok"


# ─── Orchestrator ───────────────────────────────────────────────────────────


async def run(args: argparse.Namespace) -> int:
    api_key = args.api_key or os.environ.get("DARRA_API_KEY") or ""
    if not api_key:
        LOG.error("no API key provided (use --api-key or set DARRA_API_KEY)")
        return 2

    if not args.db.exists():
        LOG.error("database not found: %s", args.db)
        return 2

    LOG.info("opening database: %s", args.db)
    with open_db(args.db) as conn:
        jobs = fetch_verse_jobs(
            conn,
            resource_id=args.translation_id,
            chapter=args.chapter,
            only_missing=not args.retry_failures,
        )

        if args.limit and len(jobs) > args.limit:
            jobs = jobs[: args.limit]

        if not jobs:
            LOG.info("no verses to align (everything is already done)")
            return 0

        LOG.info(
            "queued %d verses | model=%s | workers=%d | rate-limit=%dms",
            len(jobs), args.model, args.workers, args.rate_limit_ms,
        )

        client = LLMClient(
            api_key=api_key,
            api_base=args.api_base,
            model=args.model,
            timeout_s=args.timeout,
            rate_limit_ms=args.rate_limit_ms,
        )
        db_lock = asyncio.Lock()
        sem = asyncio.Semaphore(args.workers)
        progress = {"done": 0, "total": len(jobs), "start": time.monotonic()}

        async def _worker(job: VerseJob) -> str:
            async with sem:
                return await process_verse(
                    client, job, conn, db_lock,
                    args.translation_id, args.dry_run, progress,
                )

        tasks = [asyncio.create_task(_worker(j)) for j in jobs]

        loop = asyncio.get_running_loop()
        stop_event = asyncio.Event()

        def _handle_signal(*_: Any) -> None:
            if not stop_event.is_set():
                LOG.warning(
                    "interrupt received, cancelling pending tasks; in-flight requests will finish"
                )
                stop_event.set()
                for t in tasks:
                    if not t.done():
                        t.cancel()

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, _handle_signal)
            except NotImplementedError:
                pass

        results: list[str] = []
        for fut in asyncio.as_completed(tasks):
            try:
                results.append(await fut)
            except asyncio.CancelledError:
                results.append("cancelled")

        await client.aclose()

        summary = {k: results.count(k) for k in ("ok", "validation", "error", "cancelled")}
        LOG.info("done. %s", summary)
        return 0 if summary.get("error", 0) == 0 else 1


# ─── CLI ────────────────────────────────────────────────────────────────────


def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Align Saheeh International to per-word Arabic via an LLM, with WBW gloss as semantic anchor.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--db", type=Path, required=True, help="Path to quran.db.")
    p.add_argument("--translation-id", type=int, default=20, help="Default 20 = Saheeh International.")
    p.add_argument("--chapter", type=int, default=None, help="If set, only this surah.")
    p.add_argument("--limit", type=int, default=0, help="Cap on verses processed this run.")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    p.add_argument("--rate-limit-ms", type=int, default=DEFAULT_RATE_LIMIT_MS)
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--api-base", default=DEFAULT_API_BASE)
    p.add_argument("--api-key", default=None, help="Falls back to $DARRA_API_KEY.")
    p.add_argument("--retry-failures", action="store_true", help="Re-process verses already in DB.")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argparser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())

# align_translation_to_words

A reusable pipeline that uses a frontier LLM to align a verse-level
Quran translation (e.g. Saheeh International) to **per-word Arabic**,
producing the four pieces of data a learning app needs to render
mixed Arabic/English text at any substitution level:

| Field | Meaning |
|---|---|
| `english` | The contiguous slice of the verse translation that this Arabic word "owns". When the user has not yet learned this Arabic word, the reader can show this English phrase in its place. |
| `is_implicit` | `true` if the English phrase is a translator-supplied bracketed clarification (`[All]`, `(is)`, `[therefore]`) with no direct Arabic counterpart. Implicit phrases stay in the rendered line as English even when the surrounding Arabic words have substituted. |
| `trailing_punctuation` | Punctuation from the translation that follows this Arabic word in reading order (`,`, `.`, `;`, `?`, `—`, `:`). Lets the reader render natural English flow when many Arabic words are still showing as English. |
| `notes` | Optional 1-line note from the LLM about the grammatical class or why the implicit clarification exists. Useful for tafsir hooks; safe to ignore. |

## Why an LLM (not a heuristic aligner)?

Word-by-word translation feeds from public Quran APIs (Quran.com WBW,
Corpus Quran, etc.) **don't read like natural English** when
concatenated, because they treat each Arabic word as an isolated token
and force a literal token-per-token mapping. The result is the
"That (Is) The Book No Doubt In It..." problem.

Saheeh International (and other published full-verse translations) is
already *natural English*, but it is verse-level — there is no built-in
mapping that says "this English noun corresponds to that Arabic word."

The LLM bridges the gap: it reads the Saheeh sentence as English, reads
the Arabic words in recitation order, and tells us which English span
goes with which Arabic word — preserving punctuation, bracket
conventions, and grammatical implicit fill that a heuristic cannot
produce.

## Models

Default: `cc/claude-opus-4-7` via [router.darra.ai](https://router.darra.ai).
Override with `--model`. Tested:

| Model | Notes |
|---|---|
| `cc/claude-opus-4-7` | Default. Frontier reasoning on Arabic morphology, conservative with religious text, handles bracketed translator clarifications correctly. |
| `ag/claude-opus-4-6-thinking` | Previous default. Still strong; slightly slower thinking pass. |
| `cc/claude-sonnet-4-6` | Cheaper tier for rerun / spot-check work. |

## Output

Writes to a new table in the bundled SQLite database:

```sql
CREATE TABLE word_translations_aligned (
    verse_key            TEXT    NOT NULL,
    position             INTEGER NOT NULL,
    resource_id          INTEGER NOT NULL,
    english              TEXT    NOT NULL,
    is_implicit          INTEGER NOT NULL DEFAULT 0,
    trailing_punctuation TEXT,
    notes                TEXT,
    model_version        TEXT    NOT NULL,
    wbw_anchor           TEXT,              -- verbatim QF word-by-word gloss, kept for downstream audit
    confidence           TEXT,              -- "high" | "medium" | "low" — LLM's self-rated certainty
    PRIMARY KEY (verse_key, position, resource_id)
);
```

The two new columns (`wbw_anchor`, `confidence`) are added with
`ALTER TABLE ADD COLUMN` on existing databases — the migration is
non-destructive and re-running the script against an older DB is safe.

`resource_id` matches the [Quran Foundation translation id](https://api.quran.com/api/v4/resources/translations).
For Saheeh International it is `20`.

## Usage

```bash
# 1. Install deps (Python 3.10+)
pip install -r requirements.txt

# 2. Run a small dry-run on chapter 1 first to see output without writes
python align.py --db ../../ayyat/Resources/Data/quran.db \
                --translation-id 20 \
                --chapter 1 \
                --dry-run

# 3. Real run (resumable — safe to ctrl-C and re-run)
DARRA_API_KEY=sk-... python align.py \
    --db ../../ayyat/Resources/Data/quran.db \
    --translation-id 20 \
    --workers 6
```

Cost for the full 6,236 verses on `claude-opus-4-6-thinking`: ~$5.
With 6 concurrent workers and a 350 ms rate-limit floor, wall time
is roughly 25–35 minutes end-to-end.

The script is **resumable**: if it gets interrupted, re-running picks up
from the next verse with no aligned row. It does NOT re-call the LLM
on verses already in the table.

## Quality checks

After each LLM response, the script asserts:

1. The number of returned entries equals the number of input Arabic words.
2. `position` values match input positions (no renumbering).
3. `arabic` field of each entry is byte-identical to the input.
4. `english` is non-empty for at least 1 entry per verse.
5. Concatenating `english + trailing_punctuation` for the whole verse
   approximately matches the Saheeh sentence (lenient diff: case and
   whitespace insensitive, allows ±5 % character delta to absorb the
   diacritic differences in Allāh / Mūsā / etc.).

If any check fails the script logs the verse and skips it. A final
`--retry-failures` flag re-runs only those.

## License

MIT. Reuse for any Quran translation aligner project.

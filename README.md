<div align="center">

# ayyat · آيات

### *Read the Quran, one word at a time.*

[![iOS](https://img.shields.io/badge/iOS-17.4%2B-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-Observable-FF6B35?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Built for](https://img.shields.io/badge/Built%20for-Quran%20Foundation%20Hackathon-2EA44F)](https://launch.provisioncapital.com/quran-hackathon)
[![On-device ASR](https://img.shields.io/badge/On--device%20ASR-FastConformer%20%C2%B7%20ANE-A100FF)](https://huggingface.co/Muno459/fastconformer-quran)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)

<br>

🕌 &nbsp; **[ayyat.net](https://ayyat.net)** &nbsp; · &nbsp; 📱 TestFlight invite with submission &nbsp; · &nbsp; 🤖 ANE-accelerated FastConformer

<br>

</div>

ayyat is an iOS app that teaches non-Arabic speakers to read the Quran in its original Arabic through **progressive substitution**. You open a surah in English. As you read, individual English words get gradually replaced with their Arabic equivalents. Tap any Arabic word to hear it, see its meaning, learn its letters, and practice your own pronunciation against an on-device, ANE-accelerated FastConformer model trained specifically on Quranic recitation.

## How it works

```
Read       Slider position determines what % of the verse appears in Arabic.
Tap        Tap any Arabic word → meaning, letter-by-letter breakdown, audio, drill.
Practice   On-device FastConformer + Apple Speech grade your spoken pronunciation.
Reflect    Save personal reflections against verses (synced + publishable to QuranReflect).
Sync       Bookmarks, reading sessions, streaks and goals follow you across devices.
```

The substitution slider goes from 0 % (all English) to 80 % (all Arabic). Each Arabic word has a familiarity *score* — common words like ٱللَّه substitute first, words you've never seen substitute as you drag the slider up via a deterministic hash-based ranking. Tapping a word, getting it right in the quiz, or passing the pronunciation check moves the word up the curve so it substitutes sooner.

Out of respect for the Quran, transliteration mode is hard-capped at 70 % — the app will never render the full ayat in Latin letters. The graduation prompt at 80 % resets the slider to 10 % so the user re-builds their Arabic recognition from a small base.

## Quran Foundation API usage

ayyat hits **8 distinct Quran Foundation User-API surfaces**, plus the public Content API and Quran Reflect. Every endpoint path and body shape was verified against the official OpenAPI spec.

### Content APIs (public `api.quran.com/api/v4` mirror)

| Endpoint | Where it's used |
|---|---|
| `GET /chapters` | Chapter list, Read tab (offline-first via bundled SQLite) |
| `GET /verses/by_chapter/{n}` | Per-chapter verses when user picks a non-default translation |
| `GET /verses/random` | "Ayah of the day" hero card |
| `GET /resources/translations` | Translation picker |
| `GET /resources/tafsirs` | Tafsir source picker inside TafsirSheet |
| `GET /tafsirs/{id}/by_ayah/{key}` | In-line Tafsir overlay for any verse |
| `GET /chapter_recitations/{rec}/{ch}` | Chapter audio with word-level timing |
| `GET /chapters/{id}/info` | "About this surah" sheet |
| `GET /search` | Full-Quran search from the magnifier toolbar |

### Quran Reflect (OAuth `client_credentials`, `post` scope)

| Endpoint | Where it's used |
|---|---|
| `GET /quran-reflect/v1/posts/feed` | Community Lessons + Reflections in VerseStudySheet |

### User APIs (OIDC + `x-auth-token`, all 8 surfaces wired)

| API surface | Endpoint(s) | Where in the app |
|---|---|---|
| Bookmarks | `POST GET DELETE /v1/bookmarks` | Verse bookmark button → Learn tab list |
| Collections | `POST GET DELETE /v1/collections` + `POST /v1/collections/{id}/bookmarks` | Theme-based bookmark groups |
| Notes (Reflections) | `POST GET PATCH DELETE /v1/notes` + `/by-verse/{key}` | Verse reflection sheet + Learn tab list |
| Posts | `POST /v1/notes/{id}/publish` | "Share on QuranReflect" toggle in the reflection sheet |
| Reading Sessions | `POST /v1/reading-sessions` | Auto on session end — resume / recently-read |
| Activity Days | `POST /v1/activity-days` | Auto on session end — seconds + ranges → streak / goal credit |
| Streaks | `GET /v1/streaks/current-streak-days?type=QURAN` | Streak card on Learn tab |
| Goals | `POST /v1/goals` + `GET /v1/goals/get-todays-plan` | Daily goal sheet + Today's Progress % card |

### OAuth2 + OIDC

- **Client credentials** (`scope=post`) for the Quran Reflect posts feed.
- **Authorization code + PKCE (S256)** for user sign-in via `ASWebAuthenticationSession`. Uses the iOS 17.4+ native `Callback.https(host:path:)` API — the session intercepts the `https://ayyat.net/oauth/callback` redirect in-place via the `webcredentials:ayyat.net` Associated Domains entitlement + AASA manifest. No custom-scheme bridge, no external worker round-trip.
- Token storage: iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
- Automatic refresh with stampede protection; a dead refresh token falls back cleanly to a signed-out state instead of looping.
- Universal-link safety net (`onOpenURL` + `applinks:ayyat.net`) catches anything the in-session callback ever misses.
- Auth header is `x-auth-token` + `x-client-id` per the QF OpenAPI `securitySchemes` (not `Authorization: Bearer`).

## On-device pronunciation grading

The pronunciation check runs **two ASR engines in parallel** on the same recording:

1. **FastConformer-Quran CTC** — a NeMo FastConformer fine-tuned on Quranic recitation, exported to CoreML, **running on the Apple Neural Engine** (FP16, 1×80×800 fixed input). 0.13 % WER on the EveryAyah validation set; 13× better than the public Tarteel-Whisper baseline on the same data.
2. **Apple Speech** (`SFSpeechRecognizer`, Arabic locale) as a fallback whenever FastConformer's CTC head emits blanks on short utterances.

A custom phonetic-class matcher collapses near-homophonic Arabic consonants (د↔ت, ر↔ل, ز↔ث↔س, ك↔ق, etc.) so Apple's general-purpose Arabic ASR — which routinely substitutes common words for rare Quranic ones — still credits the user when they pronounced the right word.

The FP16 export required a `RelPositionalEncoding.xscale` clamp patch — the vanilla FP16 conversion of FastConformer produces all-NaN logprobs on real mel input because the pos-enc multiply peaks at 117 k, 1.8× the FP16 max. Documented and fixed.

## Features

### Reading experience (substitution-first)
- Progressive substitution slider (persisted per user, server-synced via Goals)
- Two learning tracks: **Arabic Script** or **Transliteration** (hard-capped at 70 %)
- Word-by-word audio highlighting during chapter recitation (Mishari + 28 other reciters)
- Tap any Arabic word → meaning + letter breakdown + word frequency
- Per-verse play, share, bookmark, copy, reflection, tafsir
- Reader toolbar: text-size A+/A−, translation toggle, three-dot context menu

### Learning system
- Vocabulary mastery (`unseen → introduced → learning → familiar → mastered`)
- Recall-based promotion (only via tap, quiz, pronunciation — never passive scroll)
- Swipe-card vocabulary quiz with confetti + glide-in animation
- Daily word card
- Achievement badges across streak, mastery, sessions, time, library milestones
- On-device pronunciation grading (FastConformer + Apple Speech ensemble)

### Content depth
- **Tafsir** overlay per verse, with source picker (Ibn Kathir default)
- **Daily Ayah** — random verse cached for the day
- **Search** across the Quran with debounced full-text queries
- **Translation picker** — all English translations + 12 other languages

### Sync & habits
- **Reflections** — write, list, edit, delete, optionally publish to QuranReflect
- **Bookmarks** — server-synced; tap to jump straight to the verse in Read tab
- **Collections** — group bookmarks into named themes ("Mercy", "Prayer", …)
- **Reading goal** — daily verse target, progress on Progress tab + Learn-tab card
- **Reading streak** — driven by the QF Activity API, with badges at 3/7/30-day marks
- **Continue Reading** — last position card resumes via cross-tab nav coordinator

### Polish
- Light / system / dark mode toggle in Settings (applied globally)
- Haptics throughout — distinct success vs error patterns
- Lock-Screen / Control-Center playback controls via MPNowPlayingInfoCenter
- Offline DB for chapter / verse text — survives airplane mode

## Architecture

```
SwiftUI · iOS 17.4+ · @Observable · MV pattern
├─ ayyat/App                ─ entry point, environment injection, deep links,
│                            cross-tab navigation coordinator
├─ ayyat/Features/QuranReader ─ ChapterListView, VerseReaderView, VerseCell,
│                              SubstitutionWordView, TafsirSheet, ReflectionSheet,
│                              ReflectionsListView, BookmarksListView,
│                              CollectionsListView, SearchView, DailyAyahCard
├─ ayyat/Features/Vocabulary  ─ Quiz, daily word, badges
├─ ayyat/Features/Progress    ─ Streak card, calendar heatmap, stats, today's goal,
│                              achievement badge grid
├─ ayyat/Features/Settings    ─ Translation picker, Goal sheet, voice AI, appearance
├─ ayyat/Features/Onboarding  ─ 5-page intro
├─ ayyat/Models               ─ Verse, Word, Tafsir, Search, Reciter, Translation
└─ ayyat/Services
   ├─ API   ─ APIClient (Content), UserAPIClient (User), OIDCAuthService,
   │          KeychainHelper, TokenManager, APIConfig, Secrets (git-ignored)
   ├─ Audio ─ AudioPlaybackManager, FastConformerQuranASR, LogMelFeatures,
   │          WordAudioPlayer, PronunciationChecker, AppleSpeechRecognizer
   └─ Storage ─ QuranDatabase (GRDB/SQLite), VocabularyStore, UserStore,
                SettingsManager
```

## Setup

### Requirements
- Xcode 15+ with iOS 17 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

### Build
```bash
cd /path/to/ayyat
xcodegen generate
open ayyat.xcodeproj
```

### API credentials
The Quran Foundation client credentials live in `ayyat/Services/API/Secrets.swift` — **git-ignored**. Copy `Secrets.example.swift` to `Secrets.swift` on a fresh checkout and paste the credentials issued by the QF developer console. Default environment is **production**.

## Data sources

- Quran text + translations: [Quran Foundation API v4](https://api-docs.quran.foundation)
- Tafsir: Ibn Kathir abridged English (resource 169) via Content API
- Translation default: Saheeh International (resource 131)
- Chapter audio: 29 reciters from `download.quranicaudio.com` via `/chapter_recitations`
- Word-by-word audio: `audio.qurancdn.com/wbw/`
- Pronunciation model: [Muno459/fastconformer-quran-coreml-offline](https://huggingface.co/Muno459/fastconformer-quran-coreml-offline) — FP16, ANE-eligible

## Team

Built by **Mostafa Mahdi** ([me@mostafa.dk](mailto:me@mostafa.dk)) for the Quran Foundation Ramadan 2026 Hackathon.

## License

Created for the Quran Foundation Hackathon. The Quran text and audio are provided by the Quran Foundation under their terms of service. Code: MIT.

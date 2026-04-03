# Bayan

**Learn to read the Quran in its original Arabic, one word at a time.**

Bayan is an iOS app that helps non-Arabic speakers gradually learn Quranic Arabic through progressive substitution. You start reading in English, and as you encounter words repeatedly, they are replaced with their original Arabic script. Tap any Arabic word to hear its pronunciation, see its meaning, and learn its letters.

Built for the [Quran Foundation Ramadan 2026 Hackathon](https://provisionlaunch.com).

## How It Works

1. **Read** — Open any surah. Verses are displayed as a mix of English and Arabic based on your learning level.
2. **Listen** — Tap any Arabic word to hear its pronunciation from the Quran audio CDN. Use the Practice button to hear it three times (normal, slow, normal).
3. **Learn** — Each word shows a letter-by-letter breakdown with Arabic letter names. Mark words as known when you're ready.
4. **Progress** — As you read more, more English words become Arabic. Track your streak, sessions, and vocabulary growth.

The substitution level slider lets you control how much Arabic you see, from 0% (all English) to 100% (all Arabic script).

## Screenshots

| Chapter List | Verse Reader | Word Learning Card |
|---|---|---|
| 114 surahs with search | Progressive substitution with word highlighting | Letter breakdown, audio drill, meaning |

## Technical Requirements (Hackathon)

### Content API Usage
- **Quran APIs** — Chapters, verses with word-by-word data (`/verses/by_chapter`)
- **Audio APIs** — Chapter recitations with word-level timing segments (`/chapter_recitations`)
- **Translation APIs** — Saheeh International English translation (resource 131)

### User API Usage
- **Bookmarks** — Save and manage verse bookmarks (local, structured for API sync)
- **Reading Sessions** — Track reading duration per surah
- **Streak Tracking** — Calculate reading streaks from session history

### Additional APIs
- **Word-by-word audio** — Per-word pronunciation from `audio.qurancdn.com/wbw/`
- **OAuth2 Authentication** — Client credentials flow for Content API access

## Architecture

- **SwiftUI** with `@Observable` (iOS 17+)
- **MV pattern** with domain stores: `QuranStore`, `VocabularyStore`, `AudioPlaybackManager`, `UserStore`, `SettingsManager`
- **OAuth2 token management** with automatic refresh and stampede prevention
- **AVPlayer** with boundary and periodic time observers for word-level audio sync
- **UserDefaults** persistence for vocabulary states, bookmarks, reading sessions, and settings

### Key Files

| File | Purpose |
|---|---|
| `VocabularyStore.swift` | Progressive substitution engine with score-based word difficulty |
| `SubstitutionWordView.swift` | Word display and learning card with letter breakdown |
| `AudioPlaybackManager.swift` | Chapter audio with word-level highlighting |
| `WordAudioPlayer.swift` | Per-word pronunciation drill (normal/slow/normal) |
| `ArabicLetterData.swift` | Arabic letter names and diacritics for word breakdown |
| `QuranicWordData.swift` | Word frequencies and root data |
| `APIClient.swift` | Authenticated Quran Foundation API client |
| `TokenManager.swift` | OAuth2 client_credentials flow |

## Setup

### Prerequisites
- Xcode 15+ with iOS 17 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build
```bash
cd Bayan
xcodegen generate
open Bayan.xcodeproj
```

Select an iOS 17+ simulator or device and run.

### API Credentials
The app uses Quran Foundation API credentials configured in `Bayan/Services/API/APIConfig.swift`. Production credentials are included for hackathon evaluation purposes.

## Features

- Progressive substitution: English to Arabic script based on learning level
- Word-by-word pronunciation from Quran audio CDN
- Pronunciation drill: hear each word 3 times (normal, slow, normal)
- Letter-by-letter Arabic word breakdown with letter names
- Word frequency data ("Appears 2,699 times in the Quran")
- "I Know This Word" instant mastery button
- Verse progress indicators (X/Y words learned per verse)
- Audio playback with word highlighting, skip, speed control
- Vocabulary quiz with self-assessment
- Reading streak and session tracking
- Bookmarks with verse sharing
- Onboarding flow with level selection
- Daily word feature
- Continue reading from last position

## Data Sources

- **Quran text and translations**: [Quran Foundation API v4](https://api-docs.quran.foundation)
- **Word-by-word audio**: [audio.qurancdn.com](https://audio.qurancdn.com)
- **Chapter audio**: Mishari Al-Afasy murattal via Quran Foundation API

## Team

Built by Mostafa Mahdi for the Quran Foundation Ramadan 2026 Hackathon.

## License

This project was created for the Quran Foundation Hackathon. The Quran text and audio are provided by the Quran Foundation under their terms of service.

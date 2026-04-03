# Bayan

**Learn to read the Quran in its original Arabic, one word at a time.**

Bayan is an iOS app that helps non-Arabic speakers gradually learn Quranic Arabic through progressive substitution. You start reading in English, and as you encounter words repeatedly, they are replaced with their original Arabic script. Tap any Arabic word to hear its pronunciation, see its meaning, and learn its individual letters.

Built for the [Quran Foundation Ramadan 2026 Hackathon](https://provisionlaunch.com).

## How It Works

1. **Read** - Open any surah. Verses are displayed as a mix of English and Arabic based on your learning level.
2. **Listen** - Play recitation with word-by-word highlighting. Tap any Arabic word to hear its pronunciation.
3. **Practice** - Use the pronunciation drill to hear each word 3 times (normal, slow, normal). Try pronouncing it yourself with the on-device speech recognition.
4. **Learn** - Each word shows a letter-by-letter breakdown with Arabic letter names. See how many times it appears in the Quran. Mark words as known when ready.
5. **Progress** - Track your reading streak, sessions, vocabulary growth, and surah completion on the Progress tab.

The substitution slider lets you control how much Arabic you see, from 0% (all English) to 100% (all Arabic script).

## Features

### Core Reading Experience
- Progressive substitution: English words gradually become Arabic script as you learn
- Audio playback with word-by-word highlighting (no text rearranging)
- Per-verse play buttons for targeted listening
- Playback speed control (0.5x to 1.5x), skip forward/back
- Full English translation displayed below (toggleable)

### Word Learning Card (tap any Arabic word)
- Arabic word displayed large with English meaning
- Letter-by-letter breakdown with Arabic letter names (RTL order)
- Word frequency ("Appears 2,699 times in the Quran")
- Listen button with animated speaker icon
- Practice button: pronunciation drill (normal, slow, normal) with step indicator
- Try Pronouncing: on-device speech recognition using Tarteel AI Whisper model (CoreML)
- "I Know This Word" button for instant mastery promotion
- Auto-play pronunciation on open (toggleable in Settings)

### Learning System
- Vocabulary tracking with mastery levels (unseen, introduced, learning, familiar, mastered)
- Score-based substitution: common words (Allah, Rahman) substitute first
- Vocabulary quiz with flashcards (Arabic script, guess meaning, self-assess)
- Daily Word feature
- Milestone celebrations (1, 5, 10, 25, 50, 100 words)

### Progress Tracking
- Reading streak with flame icon
- Reading calendar heatmap (last 28 days)
- Stats grid (sessions, minutes, words known, bookmarks)
- Vocabulary breakdown bar (mastered/familiar/learning/new)
- Surah completion indicators ("Read" label on visited surahs)
- Continue Reading card with last position

### Other Features
- Onboarding flow with Arabic level selection
- Bookmarks with persistence
- Verse sharing (Arabic + English + verse key)
- Search surahs by name or number
- Bismillah header (except Surah At-Tawbah)
- Haptic feedback throughout
- Dark mode support
- Font size settings

## Technical Requirements (Hackathon)

### Content API Usage
- **Quran APIs** - Chapters list, verses with word-by-word data (`/verses/by_chapter`)
- **Audio APIs** - Chapter recitations with word-level timing segments (`/chapter_recitations`)
- **Translation APIs** - Saheeh International English translation (resource 131)

### User API Usage
- **Bookmarks** - Save and manage verse bookmarks (local, structured for API sync)
- **Reading Sessions** - Track reading duration per surah with timestamps
- **Streak Tracking** - Calculate reading streaks from session history

### Additional APIs
- **Word-by-word audio** - Per-word pronunciation from `audio.qurancdn.com/wbw/`
- **OAuth2 Authentication** - Client credentials flow for Content API access

### On-Device AI
- **Tarteel AI Whisper** - `tarteel-ai/whisper-tiny-ar-quran` fine-tuned for Quranic Arabic
- Converted to CoreML (Encoder 16MB + Decoder 57MB)
- Real mel spectrogram via Accelerate/vDSP FFT
- Autoregressive greedy decoding with Arabic language token
- Diacritic-stripped Levenshtein comparison for pronunciation checking

## Architecture

- **SwiftUI** with `@Observable` (iOS 17+)
- **MV pattern** with domain stores injected via `@Environment`
- **OAuth2 token management** with automatic refresh and stampede prevention
- **AVPlayer** with boundary and periodic time observers for word-level audio sync
- **CoreML** for on-device Whisper inference (no network required)
- **UserDefaults** persistence with debounced saves for vocabulary states
- **Accelerate** framework for mel spectrogram computation

### Key Files

| File | Purpose |
|---|---|
| `VocabularyStore.swift` | Progressive substitution engine with score-based word difficulty |
| `SubstitutionWordView.swift` | Word display with learning card sheet |
| `AudioPlaybackManager.swift` | Chapter audio with atomic verse+word highlighting |
| `WordAudioPlayer.swift` | Per-word pronunciation drill (normal/slow/normal) |
| `PronunciationChecker.swift` | On-device Tarteel Whisper CoreML inference |
| `MelSpectrogram.swift` | Real STFT via Accelerate vDSP for Whisper input |
| `ArabicLetterData.swift` | Arabic letter names and diacritics for word breakdown |
| `QuranicWordData.swift` | Word frequencies for common Quranic vocabulary |
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
The app uses Quran Foundation API credentials configured in `Bayan/Services/API/APIConfig.swift`. Production credentials are included for hackathon evaluation.

## Data Sources

- **Quran text and translations**: [Quran Foundation API v4](https://api-docs.quran.foundation)
- **Word-by-word audio**: [audio.qurancdn.com](https://audio.qurancdn.com)
- **Chapter audio**: Mishari Al-Afasy murattal via Quran Foundation API
- **Pronunciation model**: [tarteel-ai/whisper-tiny-ar-quran](https://huggingface.co/tarteel-ai/whisper-tiny-ar-quran)

## Team

Built by Mostafa Mahdi for the Quran Foundation Ramadan 2026 Hackathon.

## License

This project was created for the Quran Foundation Hackathon. The Quran text and audio are provided by the Quran Foundation under their terms of service.

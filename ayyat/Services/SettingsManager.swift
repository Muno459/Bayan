import Foundation
import SwiftUI

/// App-wide settings and preferences
@MainActor
@Observable
final class SettingsManager {
    var arabicFontSize: CGFloat {
        didSet { UserDefaults.standard.set(arabicFontSize, forKey: "arabicFontSize") }
    }

    var translationFontSize: CGFloat {
        didSet { UserDefaults.standard.set(translationFontSize, forKey: "translationFontSize") }
    }

    var selectedReciterId: Int {
        didSet { UserDefaults.standard.set(selectedReciterId, forKey: "selectedReciterId") }
    }

    var selectedTranslationId: Int {
        didSet { UserDefaults.standard.set(selectedTranslationId, forKey: "selectedTranslationId") }
    }

    /// Whether to show the full English translation below the substitution line
    var showFullTranslation: Bool {
        didSet { UserDefaults.standard.set(showFullTranslation, forKey: "showFullTranslation") }
    }

    /// Auto-play word pronunciation when tapping a substituted word
    var autoPlayWordPronunciation: Bool {
        didSet { UserDefaults.standard.set(autoPlayWordPronunciation, forKey: "autoPlayWordPronunciation") }
    }

    /// Show transliteration as a pronunciation aid (not a replacement for Arabic)
    var showTransliteration: Bool {
        didSet { UserDefaults.standard.set(showTransliteration, forKey: "showTransliteration") }
    }

    /// What single line shows under each ayah's Arabic+substitution view.
    /// One slot only — translation and transliteration are mutually
    /// exclusive so the reading page never stacks both.
    var verseExtraLine: VerseExtraLine {
        didSet { UserDefaults.standard.set(verseExtraLine.rawValue, forKey: "verseExtraLine") }
    }

    /// Auto-open mic when viewing a word card to check pronunciation
    var autoPronunciationCheck: Bool {
        didSet { UserDefaults.standard.set(autoPronunciationCheck, forKey: "autoPronunciationCheck") }
    }

    /// Optional dark-mode override for the reader.
    /// nil = follow system. Persists across sessions.
    var darkModeOverride: DarkModeOverride {
        didSet { UserDefaults.standard.set(darkModeOverride.rawValue, forKey: "darkModeOverride") }
    }

    /// When a mixed English+Arabic line is rendered (substitution mode),
    /// should the line read right-to-left (Arabic-first) or left-to-right
    /// (English-first)? RTL is the default since that's the natural
    /// direction for any Arabic-majority line, but learners who are still
    /// reading English-first can flip it.
    var arabicMixedDirection: ArabicMixedDirection {
        didSet { UserDefaults.standard.set(arabicMixedDirection.rawValue, forKey: "arabicMixedDirection") }
    }

    /// Use the in-house FastConformer-CTC pronunciation model instead of
    /// Tarteel/WhisperKit. Off by default — flip to true to validate the
    /// new model on a real device before making it the default.
    var useFastConformer: Bool {
        didSet { UserDefaults.standard.set(useFastConformer, forKey: "useFastConformer") }
    }

    /// Run Apple Speech alongside the Quran-specialised model and
    /// reconcile both transcripts at grading time. On by default — gives
    /// more lenient matching for clearly-articulated speech. Disable if
    /// you want the Quran model's verdict to stand on its own (more
    /// strict, plus avoids Apple Speech's mid-word splits on Arabic).
    var useDualEngine: Bool {
        didSet { UserDefaults.standard.set(useDualEngine, forKey: "useDualEngine") }
    }


    enum DarkModeOverride: String, Sendable, CaseIterable {
        case system, light, dark
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light:  .light
            case .dark:   .dark
            }
        }
    }

    enum VerseExtraLine: String, Sendable, CaseIterable {
        case translation, transliteration, none
        var displayName: String {
            switch self {
            case .translation:    "Translation"
            case .transliteration: "Transliteration"
            case .none:           "None"
            }
        }
    }

    enum ArabicMixedDirection: String, Sendable, CaseIterable {
        case rtl, ltr
        var layoutDirection: LayoutDirection {
            switch self {
            case .rtl: .rightToLeft
            case .ltr: .leftToRight
            }
        }
        var displayName: String {
            switch self {
            case .rtl: "Right to left (Arabic-first)"
            case .ltr: "Left to right (English-first)"
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard

        self.arabicFontSize = defaults.object(forKey: "arabicFontSize") as? CGFloat ?? 28
        self.translationFontSize = defaults.object(forKey: "translationFontSize") as? CGFloat ?? 16
        // Default reciter: Mishari Rashid Al-Afasy (id 7) on
        // api.quran.com's /chapter_recitations endpoint. Most recognisable
        // voice in the catalog and ships with full word-by-word timings
        // for the per-word highlighting.
        self.selectedReciterId = defaults.object(forKey: "selectedReciterId") as? Int ?? 7
        // Default translation: Saheeh International on api.quran.com v4
        // is id 20 (not 131, which we used previously and turned out to
        // be an empty resource — fetches returned 0 rows, the reader
        // fell back to per-word concatenation with no punctuation).
        self.selectedTranslationId = defaults.object(forKey: "selectedTranslationId") as? Int ?? 20
        self.showFullTranslation = defaults.object(forKey: "showFullTranslation") as? Bool ?? true
        self.autoPlayWordPronunciation = defaults.object(forKey: "autoPlayWordPronunciation") as? Bool ?? true
        self.showTransliteration = defaults.object(forKey: "showTransliteration") as? Bool ?? false
        // Migrate the previous twin-toggle state. If the user had Show
        // Full Translation off but transliteration on, that maps to
        // .transliteration. Default for fresh installs is .translation.
        if let raw = defaults.string(forKey: "verseExtraLine"),
           let v = VerseExtraLine(rawValue: raw)
        {
            self.verseExtraLine = v
        } else if let legacy = defaults.object(forKey: "showFullTranslation") as? Bool, !legacy {
            self.verseExtraLine = .none
        } else {
            self.verseExtraLine = .translation
        }
        self.autoPronunciationCheck = defaults.object(forKey: "autoPronunciationCheck") as? Bool ?? false
        self.darkModeOverride = (defaults.string(forKey: "darkModeOverride").flatMap(DarkModeOverride.init(rawValue:))) ?? .system
        self.arabicMixedDirection = (defaults.string(forKey: "arabicMixedDirection").flatMap(ArabicMixedDirection.init(rawValue:))) ?? .rtl
        self.useFastConformer = defaults.bool(forKey: "useFastConformer")
        // Default ON to preserve previous behavior. UserDefaults.bool()
        // returns false for an absent key, so detect absence explicitly.
        self.useDualEngine = (defaults.object(forKey: "useDualEngine") as? Bool) ?? true
    }
}

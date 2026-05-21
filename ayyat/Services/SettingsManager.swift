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

    /// Auto-open mic when viewing a word card to check pronunciation
    var autoPronunciationCheck: Bool {
        didSet { UserDefaults.standard.set(autoPronunciationCheck, forKey: "autoPronunciationCheck") }
    }

    /// Optional dark-mode override for the reader.
    /// nil = follow system. Persists across sessions.
    var darkModeOverride: DarkModeOverride {
        didSet { UserDefaults.standard.set(darkModeOverride.rawValue, forKey: "darkModeOverride") }
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

    init() {
        let defaults = UserDefaults.standard

        self.arabicFontSize = defaults.object(forKey: "arabicFontSize") as? CGFloat ?? 28
        self.translationFontSize = defaults.object(forKey: "translationFontSize") as? CGFloat ?? 16
        // Default reciter: Saad al-Ghamdi (Murattal) — id 13 on
        // api.quran.com's /chapter_recitations endpoint. Calm, clear
        // recitation that pairs well with the substitution-learning UX.
        self.selectedReciterId = defaults.object(forKey: "selectedReciterId") as? Int ?? 13
        self.selectedTranslationId = defaults.object(forKey: "selectedTranslationId") as? Int ?? 131
        self.showFullTranslation = defaults.object(forKey: "showFullTranslation") as? Bool ?? true
        self.autoPlayWordPronunciation = defaults.object(forKey: "autoPlayWordPronunciation") as? Bool ?? true
        self.showTransliteration = defaults.object(forKey: "showTransliteration") as? Bool ?? false
        self.autoPronunciationCheck = defaults.object(forKey: "autoPronunciationCheck") as? Bool ?? false
        self.darkModeOverride = (defaults.string(forKey: "darkModeOverride").flatMap(DarkModeOverride.init(rawValue:))) ?? .system
        self.useFastConformer = defaults.bool(forKey: "useFastConformer")
        // Default ON to preserve previous behavior. UserDefaults.bool()
        // returns false for an absent key, so detect absence explicitly.
        self.useDualEngine = (defaults.object(forKey: "useDualEngine") as? Bool) ?? true
    }
}

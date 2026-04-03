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

    init() {
        let defaults = UserDefaults.standard

        self.arabicFontSize = defaults.object(forKey: "arabicFontSize") as? CGFloat ?? 28
        self.translationFontSize = defaults.object(forKey: "translationFontSize") as? CGFloat ?? 16
        self.selectedReciterId = defaults.object(forKey: "selectedReciterId") as? Int ?? 7
        self.selectedTranslationId = defaults.object(forKey: "selectedTranslationId") as? Int ?? 131
        self.showFullTranslation = defaults.object(forKey: "showFullTranslation") as? Bool ?? true
        self.autoPlayWordPronunciation = defaults.object(forKey: "autoPlayWordPronunciation") as? Bool ?? true
        self.showTransliteration = defaults.object(forKey: "showTransliteration") as? Bool ?? false
        self.autoPronunciationCheck = defaults.object(forKey: "autoPronunciationCheck") as? Bool ?? false
    }
}

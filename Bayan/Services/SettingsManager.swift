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

    var showTransliteration: Bool {
        didSet { UserDefaults.standard.set(showTransliteration, forKey: "showTransliteration") }
    }

    var showArabicScript: Bool {
        didSet { UserDefaults.standard.set(showArabicScript, forKey: "showArabicScript") }
    }

    var autoPlayAudio: Bool {
        didSet { UserDefaults.standard.set(autoPlayAudio, forKey: "autoPlayAudio") }
    }

    var autoPlayWordPronunciation: Bool {
        didSet { UserDefaults.standard.set(autoPlayWordPronunciation, forKey: "autoPlayWordPronunciation") }
    }

    init() {
        let defaults = UserDefaults.standard

        self.arabicFontSize = defaults.object(forKey: "arabicFontSize") as? CGFloat ?? 28
        self.translationFontSize = defaults.object(forKey: "translationFontSize") as? CGFloat ?? 16
        self.selectedReciterId = defaults.object(forKey: "selectedReciterId") as? Int ?? 7
        self.selectedTranslationId = defaults.object(forKey: "selectedTranslationId") as? Int ?? 131
        self.showTransliteration = defaults.object(forKey: "showTransliteration") as? Bool ?? true
        self.showArabicScript = defaults.object(forKey: "showArabicScript") as? Bool ?? false
        self.autoPlayAudio = defaults.object(forKey: "autoPlayAudio") as? Bool ?? false
        self.autoPlayWordPronunciation = defaults.object(forKey: "autoPlayWordPronunciation") as? Bool ?? true
    }
}

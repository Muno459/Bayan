import Foundation

/// A Quran translation resource from the API.
struct TranslationResource: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    let name: String
    let authorName: String?
    let languageName: String
    let translatedName: TranslatedName?

    enum CodingKeys: String, CodingKey {
        case id, name
        case authorName = "author_name"
        case languageName = "language_name"
        case translatedName = "translated_name"
    }

    struct TranslatedName: Codable, Sendable, Hashable {
        let name: String
        let languageName: String

        enum CodingKeys: String, CodingKey {
            case name
            case languageName = "language_name"
        }
    }

    /// Display name for the translation
    var displayName: String {
        if let author = authorName, !author.isEmpty {
            return "\(name) - \(author)"
        }
        return name
    }

    /// Language display name (capitalized)
    var languageDisplayName: String {
        languageName.capitalized
    }
}

/// Response from translations API
struct TranslationsResponse: Codable, Sendable {
    let translations: [TranslationResource]
}

/// Supported app languages for UI localization
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case arabic = "ar"
    case urdu = "ur"
    case turkish = "tr"
    case indonesian = "id"
    case french = "fr"
    case spanish = "es"
    case german = "de"
    case russian = "ru"
    case chinese = "zh-Hans"
    case malay = "ms"
    case bengali = "bn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .arabic: return "العربية"
        case .urdu: return "اردو"
        case .turkish: return "Türkçe"
        case .indonesian: return "Bahasa Indonesia"
        case .french: return "Français"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .russian: return "Русский"
        case .chinese: return "中文"
        case .malay: return "Bahasa Melayu"
        case .bengali: return "বাংলা"
        }
    }

    var isRTL: Bool {
        self == .arabic || self == .urdu
    }

    /// Suggested translation ID for this language
    var defaultTranslationId: Int {
        switch self {
        case .english: return 131  // Saheeh International
        case .arabic: return 816   // Arabic Tafsir
        case .urdu: return 234     // Fatah Muhammad Jalandhari
        case .turkish: return 77   // Diyanet
        case .indonesian: return 33
        case .french: return 136   // Montada
        case .spanish: return 83   // Isa Garcia
        case .german: return 27    // Bubenheim
        case .russian: return 45   // Kuliev
        case .chinese: return 56   // Ma Jain
        case .malay: return 39     // Basmeih
        case .bengali: return 161  // Taisirul
        }
    }
}

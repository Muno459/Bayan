import Foundation

/// Arabic letter data for teaching letter recognition.
/// Maps each Arabic letter to its name, isolated form, and position variants.
enum ArabicLetterData {

    struct LetterInfo {
        let name: String       // English name
        let isolated: String   // Isolated form
    }

    /// Map of Arabic characters to their letter info.
    /// Includes base letters and common variants with diacritics.
    static let letters: [Character: LetterInfo] = [
        // Base letters
        "ا": LetterInfo(name: "Alif", isolated: "ا"),
        "ٱ": LetterInfo(name: "Alif", isolated: "ا"),
        "أ": LetterInfo(name: "Alif", isolated: "ا"),
        "إ": LetterInfo(name: "Alif", isolated: "ا"),
        "آ": LetterInfo(name: "Alif Madda", isolated: "آ"),
        "ب": LetterInfo(name: "Ba", isolated: "ب"),
        "ت": LetterInfo(name: "Ta", isolated: "ت"),
        "ث": LetterInfo(name: "Tha", isolated: "ث"),
        "ج": LetterInfo(name: "Jeem", isolated: "ج"),
        "ح": LetterInfo(name: "Ha", isolated: "ح"),
        "خ": LetterInfo(name: "Kha", isolated: "خ"),
        "د": LetterInfo(name: "Dal", isolated: "د"),
        "ذ": LetterInfo(name: "Dhal", isolated: "ذ"),
        "ر": LetterInfo(name: "Ra", isolated: "ر"),
        "ز": LetterInfo(name: "Zay", isolated: "ز"),
        "س": LetterInfo(name: "Seen", isolated: "س"),
        "ش": LetterInfo(name: "Sheen", isolated: "ش"),
        "ص": LetterInfo(name: "Sad", isolated: "ص"),
        "ض": LetterInfo(name: "Dad", isolated: "ض"),
        "ط": LetterInfo(name: "Taa", isolated: "ط"),
        "ظ": LetterInfo(name: "Dhaa", isolated: "ظ"),
        "ع": LetterInfo(name: "Ayn", isolated: "ع"),
        "غ": LetterInfo(name: "Ghayn", isolated: "غ"),
        "ف": LetterInfo(name: "Fa", isolated: "ف"),
        "ق": LetterInfo(name: "Qaf", isolated: "ق"),
        "ك": LetterInfo(name: "Kaf", isolated: "ك"),
        "ل": LetterInfo(name: "Lam", isolated: "ل"),
        "م": LetterInfo(name: "Meem", isolated: "م"),
        "ن": LetterInfo(name: "Nun", isolated: "ن"),
        "ه": LetterInfo(name: "Ha", isolated: "ه"),
        "و": LetterInfo(name: "Waw", isolated: "و"),
        "ي": LetterInfo(name: "Ya", isolated: "ي"),
        "ى": LetterInfo(name: "Alif Maqsura", isolated: "ى"),
        "ة": LetterInfo(name: "Ta Marbuta", isolated: "ة"),
        "ء": LetterInfo(name: "Hamza", isolated: "ء"),
        "ئ": LetterInfo(name: "Hamza", isolated: "ء"),
        "ؤ": LetterInfo(name: "Hamza", isolated: "ء"),

        // Lam-Alif ligature
        "ﻻ": LetterInfo(name: "Lam-Alif", isolated: "لا"),
        "ﻵ": LetterInfo(name: "Lam-Alif Madda", isolated: "لآ"),

        // Alif Wasla (common in Uthmani)
        "ٱ": LetterInfo(name: "Alif Wasla", isolated: "ا"),
    ]

    /// Diacritic marks (tashkeel) - these modify letter sounds
    static let diacritics: [Character: String] = [
        "\u{064E}": "Fathah (a)",      // َ
        "\u{064F}": "Dammah (u)",      // ُ
        "\u{0650}": "Kasrah (i)",      // ِ
        "\u{0651}": "Shaddah (double)", // ّ
        "\u{0652}": "Sukun (stop)",    // ْ
        "\u{064B}": "Tanween (an)",    // ً
        "\u{064C}": "Tanween (un)",    // ٌ
        "\u{064D}": "Tanween (in)",    // ٍ
        "\u{0653}": "Maddah (extend)", // ٓ
        "\u{0654}": "Hamza above",     // ٔ
        "\u{0670}": "Alif Khanjariya", // ٰ

        // Uthmani-specific diacritics
        "\u{06E1}": "Sukun",           // ۡ
        "\u{06E4}": "Small Madda",     // ۤ
        "\u{08F0}": "Open Fathatan",   // ࣰ
        "\u{08F1}": "Open Dammatan",   // ࣱ
        "\u{08F2}": "Open Kasratan",   // ࣲ
    ]

    /// Break an Arabic word into its constituent letters with diacritics grouped.
    /// Returns an array of (displayChar, letterName, diacriticNames)
    static func breakdownWord(_ text: String) -> [LetterBreakdown] {
        var result: [LetterBreakdown] = []

        var currentBase: Character?
        var currentDisplay = ""
        var currentDiacritics: [String] = []

        for scalar in text.unicodeScalars {
            let char = Character(scalar)

            if let diacriticName = diacritics[char] {
                // This is a diacritic — attach to current letter
                currentDisplay.append(char)
                currentDiacritics.append(diacriticName)
            } else if let letterInfo = letters[char] {
                // New base letter — save previous if exists
                if let base = currentBase {
                    let name = letters[base]?.name ?? ""
                    result.append(LetterBreakdown(
                        display: currentDisplay,
                        letterName: name,
                        diacritics: currentDiacritics
                    ))
                }
                currentBase = char
                currentDisplay = String(char)
                currentDiacritics = []
            }
            // Skip unknown characters (tatweel, ZWJ, etc.)
        }

        // Save last letter
        if let base = currentBase {
            let name = letters[base]?.name ?? ""
            result.append(LetterBreakdown(
                display: currentDisplay,
                letterName: name,
                diacritics: currentDiacritics
            ))
        }

        return result
    }
}

struct LetterBreakdown: Identifiable {
    let id = UUID()
    let display: String       // The letter with its diacritics
    let letterName: String    // English name of the base letter
    let diacritics: [String]  // Names of attached diacritics
}

import Foundation

/// Static Quranic word data: roots, frequencies, and related words.
/// This provides linguistic context for the word learning popover.
enum QuranicWordData {

    // MARK: - Word Frequency (approximate counts across the full Quran)

    /// Common Quranic word frequencies. Key is the Arabic text (Uthmani).
    static let wordFrequencies: [String: Int] = [
        "ٱللَّهِ": 1672, "ٱللَّهُ": 980, "ٱللَّهَ": 592,
        "رَبِّ": 124, "رَبَّ": 58, "رَبُّ": 73, "رَبِّكَ": 72,
        "قَالَ": 529, "قَالُوا۟": 332, "قُلْ": 332,
        "ٱلَّذِينَ": 811,
        "كَانَ": 359, "كَانُوا۟": 199,
        "إِنَّ": 493, "إِنَّا": 93,
        "مِنَ": 567, "مِن": 1191,
        "عَلَىٰ": 479,
        "فِى": 236, "فِي": 287,
        "لَا": 812,
        "مَا": 833,
        "هُوَ": 255,
        "إِلَّا": 341,
        "بِسْمِ": 3,
        "ٱلرَّحْمَـٰنِ": 45, "ٱلرَّحِيمِ": 34,
        "ٱلْعَـٰلَمِينَ": 42,
        "يَوْمِ": 52, "يَوْمَ": 42,
        "ٱلدِّينِ": 48,
        "إِيَّاكَ": 2,
        "نَعْبُدُ": 1,
        "نَسْتَعِينُ": 1,
        "ٱهْدِنَا": 1,
        "ٱلصِّرَٰطَ": 5,
        "ٱلْمُسْتَقِيمَ": 6,
        "صِرَٰطَ": 5,
        "أَنْعَمْتَ": 1,
        "عَلَيْهِمْ": 55,
        "غَيْرِ": 12,
        "ٱلْمَغْضُوبِ": 1,
        "وَلَا": 173,
        "ٱلضَّآلِّينَ": 1,
    ]

    /// Get frequency for a word, returns nil if unknown
    static func frequency(for arabicText: String) -> Int? {
        wordFrequencies[arabicText]
    }

    // MARK: - Arabic Root System

    /// Known root letters for common Quranic words
    /// Key: Arabic word text, Value: (root letters, root meaning)
    static let wordRoots: [String: (root: String, meaning: String)] = [
        // ر ح م - mercy
        "ٱلرَّحْمَـٰنِ": ("ر ح م", "mercy, compassion"),
        "ٱلرَّحِيمِ": ("ر ح م", "mercy, compassion"),
        "رَحْمَةً": ("ر ح م", "mercy, compassion"),
        "رَحْمَتِ": ("ر ح م", "mercy, compassion"),
        "يَرْحَمُ": ("ر ح م", "mercy, compassion"),
        "ٱرْحَمْ": ("ر ح م", "mercy, compassion"),

        // ع ل م - knowledge
        "ٱلْعَـٰلَمِينَ": ("ع ل م", "knowledge, world"),
        "عَلِمَ": ("ع ل م", "knowledge, world"),
        "يَعْلَمُ": ("ع ل م", "knowledge, world"),
        "عِلْمٌ": ("ع ل م", "knowledge, world"),
        "عَلِيمٌ": ("ع ل م", "knowledge, world"),

        // ع ب د - worship, servitude
        "نَعْبُدُ": ("ع ب د", "worship, servitude"),
        "عِبَادِ": ("ع ب د", "worship, servitude"),
        "عَبْدِ": ("ع ب د", "worship, servitude"),

        // ه د ي - guidance
        "ٱهْدِنَا": ("ه د ي", "guidance"),
        "هُدًى": ("ه د ي", "guidance"),
        "ٱلْهُدَىٰ": ("ه د ي", "guidance"),
        "يَهْدِى": ("ه د ي", "guidance"),

        // ق و ل - speech
        "قَالَ": ("ق و ل", "speech, saying"),
        "قَالُوا۟": ("ق و ل", "speech, saying"),
        "قُلْ": ("ق و ل", "speech, saying"),
        "يَقُولُ": ("ق و ل", "speech, saying"),

        // ك و ن - being
        "كَانَ": ("ك و ن", "being, existence"),
        "كَانُوا۟": ("ك و ن", "being, existence"),
        "يَكُونُ": ("ك و ن", "being, existence"),

        // أ م ن - belief, safety
        "ءَامَنُوا۟": ("أ م ن", "belief, trust, safety"),
        "ٱلْمُؤْمِنِينَ": ("أ م ن", "belief, trust, safety"),
        "إِيمَـٰنًا": ("أ م ن", "belief, trust, safety"),

        // ص ل و - prayer
        "ٱلصَّلَوٰةَ": ("ص ل و", "prayer, connection"),
        "صَلَوٰتِ": ("ص ل و", "prayer, connection"),
        "يُصَلِّى": ("ص ل و", "prayer, connection"),

        // ك ف ر - disbelief
        "كَفَرُوا۟": ("ك ف ر", "disbelief, covering"),
        "ٱلْكَـٰفِرِينَ": ("ك ف ر", "disbelief, covering"),

        // س م و - sky, elevation
        "ٱلسَّمَـٰوَٰتِ": ("س م و", "sky, elevation"),
        "سَمَآءِ": ("س م و", "sky, elevation"),

        // أ ر ض - earth, land
        "ٱلْأَرْضِ": ("أ ر ض", "earth, land"),
        "أَرْضًا": ("أ ر ض", "earth, land"),

        // ن ع م - blessing, favor
        "أَنْعَمْتَ": ("ن ع م", "blessing, favor"),
        "نِعْمَةَ": ("ن ع م", "blessing, favor"),

        // غ ض ب - anger
        "ٱلْمَغْضُوبِ": ("غ ض ب", "anger, wrath"),

        // ض ل ل - straying
        "ٱلضَّآلِّينَ": ("ض ل ل", "straying, going astray"),

        // إله - deity
        "ٱللَّهِ": ("إ ل ه", "deity, God"),
        "ٱللَّهُ": ("إ ل ه", "deity, God"),
        "ٱللَّهَ": ("إ ل ه", "deity, God"),

        // د ي ن - religion, judgment
        "ٱلدِّينِ": ("د ي ن", "religion, judgment, recompense"),

        // س م و - name
        "بِسْمِ": ("س م و", "name"),
    ]

    /// Get root info for a word
    static func rootInfo(for arabicText: String) -> (root: String, meaning: String)? {
        wordRoots[arabicText]
    }

    /// Find all words in the dictionary that share the same root
    static func relatedWords(for arabicText: String) -> [(arabic: String, meaning: String)] {
        guard let rootInfo = wordRoots[arabicText] else { return [] }
        let root = rootInfo.root

        return wordRoots
            .filter { $0.value.root == root && $0.key != arabicText }
            .map { (arabic: $0.key, meaning: "") }
            .sorted { $0.arabic < $1.arabic }
    }
}

import Foundation

/// Per-lemma learning state, keyed in `VocabularyStore.learnedLemmas`
/// by the diacritized lemma text (e.g. `"اللَّه"`).
///
/// Persisted to UserDefaults via the same debounced JSON path as
/// `wordStates`. The struct is intentionally small — three Codable
/// scalars — so a user with hundreds of learned lemmas still serialises
/// to a couple of kilobytes.
struct LemmaProgress: Codable, Sendable, Equatable {
    /// When the user first tapped "I Know This Word" for any inflection
    /// of this lemma.
    var learnedAt: Date

    /// Number of times the user has read a verse containing this lemma
    /// **without** tapping for help. Rises 0 → 3, then the lemma
    /// graduates from training-wheels rendering (Arabic + faded
    /// transliteration) to bare Arabic. Capped at `graduationThreshold`
    /// — there's no further state past 3.
    var silentEncounters: Int

    /// Last time this lemma was seen on screen — useful for future
    /// retention metrics. Not used in any render decision today.
    var lastSeenAt: Date?

    /// Encounters needed to graduate to bare-Arabic rendering.
    /// Three is a felt-right balance: enough to feel deliberate, not so
    /// many that the training-wheels phase overstays its welcome.
    static let graduationThreshold = 3
}

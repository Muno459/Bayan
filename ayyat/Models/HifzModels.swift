import Foundation

/// Per-verse memorization state.
///
/// The reveal level mirrors the substitution slider but inverted:
/// `1.0` = the entire ayah is visible (you read it normally), `0.0` = the
/// ayah is fully blanked (you must recite from memory). Mastery feeds
/// the *priority* of hiding — words you already know are hidden first,
/// because hiding what you've never seen is unfair.
///
/// Progression follows a light SM-2 spaced-repetition curve:
///   - first pass        → interval 1 day
///   - second pass       → 3 days
///   - third pass        → 7 days
///   - subsequent passes → previousInterval × easiness (default 2.0)
///   - any miss          → reset interval to 1 day, easiness × 0.85
struct HifzState: Codable, Sendable, Identifiable {
    let verseKey: String           // "2:255"
    let chapterId: Int

    /// 1.0 = fully visible. 0.0 = blanked / recall-only.
    var revealLevel: Double = 1.0

    /// Number of consecutive passes at the current reveal level.
    var streak: Int = 0

    /// SM-2-style ease factor. Above 1.3.
    var easiness: Double = 2.5

    /// Days until next review.
    var intervalDays: Int = 0

    /// When the verse was last attempted.
    var lastReviewedAt: Date?

    /// When the verse is due for the next review.
    var nextDueAt: Date?

    /// Total successful recall attempts since starting.
    var totalPasses: Int = 0

    /// Total failed attempts since starting.
    var totalMisses: Int = 0

    /// First time this verse was added to the memorization queue.
    let addedAt: Date

    var id: String { verseKey }

    /// True when reveal level is 0 *and* the user has at least 3 consecutive
    /// passes from blind state. This is the threshold for "memorized".
    var isMemorized: Bool {
        revealLevel <= 0.001 && totalPasses >= 3 && streak >= 3
    }

    /// True when the verse should appear in today's queue.
    func isDueToday(now: Date = Date()) -> Bool {
        guard let due = nextDueAt else { return true }
        return due <= now
    }

    /// Progress label suitable for a list row.
    var statusLabel: String {
        if isMemorized { return "Memorized" }
        if revealLevel >= 0.99 { return "New" }
        if revealLevel <= 0.001 { return "Recalling blind" }
        return "\(Int((1 - revealLevel) * 100))% hidden"
    }

    init(
        verseKey: String,
        chapterId: Int,
        addedAt: Date = Date()
    ) {
        self.verseKey = verseKey
        self.chapterId = chapterId
        self.addedAt = addedAt
    }
}

/// Decision returned after a recall attempt.
enum HifzResult: Sendable {
    case pass
    case partial   // got most of it right; level up softly
    case fail
}

/// Scheduling math, lifted out of the store so it's pure-functional + testable.
enum HifzScheduler {

    /// How many ayahs ahead to advance after a pass at a given reveal level.
    /// Coarser steps at the start (visible → 70%) and finer steps closer to
    /// blind, so the user gets repeated practice at the hardest layers.
    static func nextRevealLevel(from current: Double, after result: HifzResult) -> Double {
        switch result {
        case .pass:
            if current > 0.7  { return max(0.5, current - 0.25) }
            if current > 0.4  { return max(0.2, current - 0.2)  }
            if current > 0.1  { return max(0.0, current - 0.15) }
            return 0.0
        case .partial:
            return max(0.0, current - 0.05)
        case .fail:
            return min(1.0, current + 0.2)
        }
    }

    /// Apply a recall attempt to a state. Returns the updated state.
    /// SM-2-ish on the interval/easiness axis.
    static func apply(_ result: HifzResult, to state: HifzState, now: Date = Date()) -> HifzState {
        var s = state
        s.lastReviewedAt = now

        switch result {
        case .pass:
            s.streak += 1
            s.totalPasses += 1
            s.revealLevel = nextRevealLevel(from: state.revealLevel, after: .pass)

            // Interval ladder
            switch s.streak {
            case 1: s.intervalDays = 1
            case 2: s.intervalDays = 3
            case 3: s.intervalDays = 7
            default:
                s.intervalDays = max(1, Int(Double(s.intervalDays) * s.easiness))
            }
            // Slight easiness bump on long-streak passes.
            if s.streak >= 4 {
                s.easiness = min(3.0, s.easiness + 0.05)
            }

        case .partial:
            // Treat as a half-step — small interval bump, no streak change.
            // Critical: interval MUST grow, otherwise a verse stuck on
            // partials forever stays due every day. 20% growth, floor at 1d.
            s.totalPasses += 1
            s.revealLevel = nextRevealLevel(from: state.revealLevel, after: .partial)
            s.intervalDays = max(1, Int(Double(max(1, s.intervalDays)) * 1.2))

        case .fail:
            s.streak = 0
            s.totalMisses += 1
            s.revealLevel = nextRevealLevel(from: state.revealLevel, after: .fail)
            s.intervalDays = 1
            s.easiness = max(1.3, s.easiness * 0.85)
        }

        s.nextDueAt = Calendar.current.date(byAdding: .day, value: s.intervalDays, to: now)
        return s
    }
}

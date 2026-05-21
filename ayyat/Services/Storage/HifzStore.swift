import Foundation
import SwiftUI

/// Memorization (hifz) progress store. One `HifzState` per verse the user
/// has chosen to memorize. Persistence: UserDefaults (encoded dict).
///
/// The store is the source of truth for the gating logic — `isUnlocked`
/// drives whether the Hifz tab appears in the root tab bar.
@MainActor
@Observable
final class HifzStore {

    /// Per-verse memorization state, keyed by verseKey ("2:255").
    private(set) var states: [String: HifzState] = [:] {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    /// Default ID picked the first time we run.
    init() {
        load()
    }

    // MARK: - Public API

    /// All verses the user is currently memorizing.
    var allVerses: [HifzState] {
        Array(states.values).sorted { lhs, rhs in
            // Due today first, then by next due date, then by added time.
            let lDue = lhs.isDueToday()
            let rDue = rhs.isDueToday()
            if lDue != rDue { return lDue }
            return (lhs.nextDueAt ?? lhs.addedAt) < (rhs.nextDueAt ?? rhs.addedAt)
        }
    }

    /// Verses currently due for review.
    var dueToday: [HifzState] {
        allVerses.filter { $0.isDueToday() && !$0.isMemorized }
    }

    /// Verses that have been completed.
    var memorized: [HifzState] {
        allVerses.filter(\.isMemorized)
    }

    /// In-progress (added, not yet memorized).
    var inProgress: [HifzState] {
        allVerses.filter { !$0.isMemorized }
    }

    /// Add a verse to the memorization queue. No-op if already present.
    func enroll(verseKey: String, chapterId: Int) {
        guard states[verseKey] == nil else { return }
        let new = HifzState(verseKey: verseKey, chapterId: chapterId)
        states[verseKey] = new
    }

    /// Remove a verse from the queue.
    func remove(verseKey: String) {
        states.removeValue(forKey: verseKey)
    }

    /// Apply the result of a recall attempt.
    func record(_ result: HifzResult, for verseKey: String) {
        guard let state = states[verseKey] else { return }
        states[verseKey] = HifzScheduler.apply(result, to: state)
        Haptics.success()
    }

    /// Manually adjust reveal level (e.g. from the slider).
    func setRevealLevel(_ level: Double, for verseKey: String) {
        guard var state = states[verseKey] else { return }
        state.revealLevel = max(0, min(1, level))
        states[verseKey] = state
    }

    func contains(verseKey: String) -> Bool {
        states[verseKey] != nil
    }

    // MARK: - Gating

    /// Whether the Hifz tab is unlocked.
    /// Unlocks when the user has at least 25 words at familiar+ mastery
    /// *or* has explicitly enrolled any verse. The first condition keeps the
    /// tab hidden for fresh installs so users discover the reading mechanic
    /// before being asked to memorize; the second lets returning power users
    /// keep their queue regardless.
    func isUnlocked(familiarOrAbove: Int) -> Bool {
        familiarOrAbove >= 25 || !states.isEmpty
    }

    // MARK: - Persistence

    private let key = "ayyat.hifzStates"

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let snapshot = states
            let key = self.key
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: HifzState].self, from: data)
        else { return }
        states = saved
    }
}

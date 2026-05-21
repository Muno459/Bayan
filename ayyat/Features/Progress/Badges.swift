import SwiftUI

/// Achievement badges — earned milestones surfaced on the Progress tab.
///
/// Earned state is **derived** from `UserStore` + `VocabularyStore`
/// rather than persisted separately. That keeps it self-correcting if
/// the underlying counts ever drift (e.g. a session is deleted),
/// and removes a class of "badge state out of sync" bugs.
///
/// Newly-earned badges are detected by diffing against a UserDefaults-
/// stored set of previously-earned ids — the diff drives a one-shot
/// `BadgeUnlockedToast` overlay so the user gets a celebration moment.
struct Badge: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let iconName: String        // SF Symbol
    let tint: Color
    let earnedAt: Date?         // nil when not yet earned (uses today on first earn)
    let progress: Double        // 0...1, useful for partial-progress display

    var isEarned: Bool { earnedAt != nil }
}

enum BadgeCatalog {
    /// Snapshot all badges + earned/locked state for the current user.
    /// Ordering: earned first (most recent), then in-progress by completion.
    @MainActor
    static func snapshot(userStore: UserStore, vocab: VocabularyStore) -> [Badge] {
        let streakDays = userStore.effectiveStreakDays
        let totalSessions = userStore.sessions.count
        let totalMinutes = userStore.streak.totalMinutes
        let mastered = vocab.masteredCount
        let familiar = vocab.familiarCount
        let learning = vocab.learningCount
        let totalWords = vocab.totalWordsEncountered
        let bookmarks = userStore.bookmarks.count

        // Each spec: (id, name, desc, icon, tint, currentValue, target)
        let specs: [(String, String, String, String, Color, Int, Int)] = [
            // Streak ladder
            ("streak_3",   "Three-day streak",  "Read on 3 consecutive days.",          "flame",                .orange,                  streakDays, 3),
            ("streak_7",   "Week of light",     "7-day reading streak.",                "flame.fill",           .orange,                  streakDays, 7),
            ("streak_30", "Month of devotion", "30-day reading streak.",               "flame.circle.fill",    .red,                     streakDays, 30),

            // Vocabulary ladder
            ("vocab_10",  "First steps",       "Encounter 10 Arabic words.",           "leaf",                 .mint,                    totalWords, 10),
            ("vocab_50",  "Growing roots",     "Encounter 50 Arabic words.",           "leaf.fill",            .green,                   totalWords, 50),
            ("vocab_200", "Garden of words",   "Encounter 200 Arabic words.",          "tree.fill",            .green,                   totalWords, 200),

            // Mastery ladder
            ("master_5",  "First mastery",     "Master 5 words.",                      "checkmark.seal",       AyyatColors.mastered,     mastered,   5),
            ("master_25", "Word keeper",       "Master 25 words.",                     "checkmark.seal.fill",  AyyatColors.mastered,     mastered,   25),
            ("master_100","Vocabulary scholar","Master 100 words.",                    "graduationcap.fill",   AyyatColors.gold,         mastered,   100),

            // Sessions
            ("session_10","Habit forming",     "Complete 10 reading sessions.",        "book",                 AyyatColors.primary,      totalSessions, 10),
            ("session_50","Daily companion",   "Complete 50 reading sessions.",        "book.fill",            AyyatColors.primary,      totalSessions, 50),

            // Time
            ("time_30",   "Half-hour focus",   "Read for 30 minutes total.",           "clock",                .indigo,                  totalMinutes, 30),
            ("time_180",  "Three-hour journey","Read for 3 hours total.",              "clock.fill",           .indigo,                  totalMinutes, 180),

            // Library / collection
            ("bm_1",      "First bookmark",    "Save your first verse.",               "bookmark.fill",        AyyatColors.gold,         bookmarks,   1),
            ("bm_10",     "Curator",           "Save 10 verses to revisit.",           "bookmarks.fill",       AyyatColors.gold,         bookmarks,   10),

            // Vocabulary spread
            ("familiar_10", "Familiar phrases", "Get 10 words to familiar level.",     "star",                 .yellow,                  familiar,    10),
            ("learning_5", "Active learner",    "5 words actively being learned.",     "sparkles",             .pink,                    learning,    5),
        ]

        return specs.map { id, name, desc, icon, tint, current, target in
            let earned = current >= target
            let pct = target == 0 ? 0 : min(1.0, Double(current) / Double(target))
            return Badge(
                id: id,
                name: name,
                description: desc,
                iconName: icon,
                tint: tint,
                earnedAt: earned ? Date() : nil,
                progress: pct
            )
        }
        // Earned first (most recently unlocked at the top), then locked
        // sorted by closest-to-completion so the user sees what's next.
        .sorted { a, b in
            if a.isEarned != b.isEarned { return a.isEarned && !b.isEarned }
            if a.isEarned { return true }
            return a.progress > b.progress
        }
    }

    /// IDs of badges previously seen as earned. Diffing this against
    /// the current snapshot finds badges to celebrate.
    static func loadPreviouslyEarned() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: "ayyat.badges.earned") ?? []
        return Set(arr)
    }

    static func savePreviouslyEarned(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: "ayyat.badges.earned")
    }
}

// MARK: - Badge grid

struct BadgeGridView: View {
    let badges: [Badge]
    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(badges) { badge in
                BadgeChip(badge: badge)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct BadgeChip: View {
    let badge: Badge
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(badge.isEarned ? badge.tint.opacity(0.18) : Color.secondary.opacity(0.08))
                    .frame(width: 60, height: 60)
                if badge.isEarned {
                    Circle()
                        .stroke(badge.tint.opacity(pulse ? 0.0 : 0.5), lineWidth: 2)
                        .frame(width: 60, height: 60)
                        .scaleEffect(pulse ? 1.45 : 1.0)
                        .animation(
                            .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                            value: pulse
                        )
                        .onAppear { pulse = true }
                }
                Image(systemName: badge.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(badge.isEarned ? badge.tint : Color.secondary.opacity(0.5))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(badge.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badge.isEarned ? AyyatColors.textPrimary : AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            // Progress hint on locked badges so the user knows how close
            // they are. Shows N/M.
            if !badge.isEarned {
                Text("\(Int(badge.progress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AyyatColors.textSecondary.opacity(0.7))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(badge.isEarned
                      ? badge.tint.opacity(0.05)
                      : AyyatColors.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(badge.isEarned
                                       ? badge.tint.opacity(0.25)
                                       : Color.secondary.opacity(0.08),
                                       lineWidth: 1)
                )
        )
    }
}

// MARK: - Unlock toast

/// One-shot toast that flies in when a new badge is earned. Drives
/// haptic + a brief star-burst animation.
struct BadgeUnlockedToast: View {
    let badge: Badge
    @State private var visible = false
    @State private var rotateStar = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [badge.tint, badge.tint.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 42, height: 42)
                Image(systemName: badge.iconName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                // Spinning star sparkle behind the icon
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(x: 18, y: -16)
                    .rotationEffect(.degrees(rotateStar ? 360 : 0))
                    .animation(.linear(duration: 2.5).repeatForever(autoreverses: false),
                               value: rotateStar)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Badge unlocked")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .textCase(.uppercase)
                Text(badge.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(
                            colors: [.black.opacity(0.65), .black.opacity(0.45)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        .shadow(color: badge.tint.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .offset(y: visible ? 0 : -150)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                visible = true
            }
            rotateStar = true
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                withAnimation(.easeIn(duration: 0.35)) { visible = false }
            }
        }
    }
}

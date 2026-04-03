import SwiftUI

/// Progress tab with reading streak, calendar heatmap, vocabulary growth, and surah stats.
struct ProgressTabView: View {
    @Environment(UserStore.self) private var userStore
    @Environment(VocabularyStore.self) private var vocabularyStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Streak hero
                    streakCard

                    // Reading calendar
                    readingCalendar

                    // Stats grid
                    statsGrid

                    // Vocabulary breakdown bar
                    vocabBreakdown
                }
                .padding(.top, 8)
            }
            .background(BayanColors.background)
            .navigationTitle("Progress")
        }
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 36))
                .foregroundStyle(userStore.streak.currentDays > 0 ? BayanColors.gold : BayanColors.unseen)

            Text("\(userStore.streak.currentDays)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(BayanColors.primary)

            Text(userStore.streak.currentDays == 1 ? "Day Streak" : "Days Streak")
                .font(.system(size: 15))
                .foregroundStyle(BayanColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Reading Calendar (last 28 days)

    private var readingCalendar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 4 Weeks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BayanColors.textSecondary)

            let days = last28Days()
            let readDates = readingDates()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                // Day labels
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BayanColors.textSecondary)
                        .frame(height: 16)
                }

                // Day cells
                ForEach(days, id: \.self) { date in
                    let isRead = readDates.contains(Calendar.current.startOfDay(for: date))
                    let isToday = Calendar.current.isDateInToday(date)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isRead ? BayanColors.primary :
                            isToday ? BayanColors.primary.opacity(0.15) :
                            BayanColors.textSecondary.opacity(0.08)
                        )
                        .frame(height: 28)
                        .overlay {
                            if isToday {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(BayanColors.primary, lineWidth: 1.5)
                            }
                        }
                }
            }

            // Legend
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(BayanColors.primary).frame(width: 10, height: 10)
                    Text("Read").font(.system(size: 10)).foregroundStyle(BayanColors.textSecondary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(BayanColors.textSecondary.opacity(0.08)).frame(width: 10, height: 10)
                    Text("No activity").font(.system(size: 10)).foregroundStyle(BayanColors.textSecondary)
                }
            }
        }
        .padding(16)
        .bayanCard()
        .padding(.horizontal, 16)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ProgressStatCard(title: "Sessions", value: "\(userStore.streak.totalSessions)", icon: "book.closed.fill", color: BayanColors.primary)
            ProgressStatCard(title: "Minutes", value: "\(userStore.streak.totalMinutes)", icon: "clock.fill", color: BayanColors.learning)
            ProgressStatCard(title: "Words Known", value: "\(vocabularyStore.masteredCount + vocabularyStore.familiarCount)", icon: "character.book.closed.fill", color: BayanColors.mastered)
            ProgressStatCard(title: "Bookmarks", value: "\(userStore.bookmarks.count)", icon: "bookmark.fill", color: BayanColors.gold)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Vocab Breakdown

    private var vocabBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vocabulary")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BayanColors.textSecondary)

            let total = max(vocabularyStore.totalWordsEncountered, 1)
            let mastered = vocabularyStore.masteredCount
            let familiar = vocabularyStore.familiarCount
            let learning = vocabularyStore.learningCount
            let other = total - mastered - familiar - learning

            // Stacked progress bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if mastered > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(BayanColors.mastered)
                            .frame(width: geo.size.width * CGFloat(mastered) / CGFloat(total))
                    }
                    if familiar > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(BayanColors.introduced)
                            .frame(width: geo.size.width * CGFloat(familiar) / CGFloat(total))
                    }
                    if learning > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(BayanColors.learning)
                            .frame(width: geo.size.width * CGFloat(learning) / CGFloat(total))
                    }
                    if other > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(BayanColors.unseen)
                            .frame(width: geo.size.width * CGFloat(other) / CGFloat(total))
                    }
                }
            }
            .frame(height: 12)

            // Legend
            HStack(spacing: 14) {
                vocabLegend(color: BayanColors.mastered, label: "Mastered", count: mastered)
                vocabLegend(color: BayanColors.introduced, label: "Familiar", count: familiar)
                vocabLegend(color: BayanColors.learning, label: "Learning", count: learning)
                vocabLegend(color: BayanColors.unseen, label: "New", count: other)
            }
            .font(.system(size: 11))

            Text("\(total) total words encountered")
                .font(.system(size: 12))
                .foregroundStyle(BayanColors.textSecondary)
        }
        .padding(16)
        .bayanCard()
        .padding(.horizontal, 16)
    }

    private func vocabLegend(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)").fontWeight(.medium).foregroundStyle(BayanColors.textPrimary)
        }
    }

    // MARK: - Helpers

    private func last28Days() -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Find the start of the week 4 weeks ago
        let weekday = cal.component(.weekday, from: today)
        let startOffset = -(weekday - 1) - 21 // 4 weeks back, aligned to Sunday
        return (0..<28).compactMap { cal.date(byAdding: .day, value: startOffset + $0, to: today) }
    }

    private func readingDates() -> Set<Date> {
        let cal = Calendar.current
        return Set(userStore.sessions.compactMap { s in
            s.endedAt.map { cal.startOfDay(for: $0) }
        })
    }
}

private struct ProgressStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(BayanColors.textPrimary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(BayanColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .bayanCard()
    }
}

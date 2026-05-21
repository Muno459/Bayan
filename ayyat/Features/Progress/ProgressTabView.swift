import SwiftUI

/// Progress tab with reading streak, calendar heatmap, vocabulary growth, and surah stats.
struct ProgressTabView: View {
    @Environment(UserStore.self) private var userStore
    @Environment(VocabularyStore.self) private var vocabularyStore
    @AppStorage("ayyat.dailyVerseGoal") private var dailyGoal: Int = 10
    @State private var showGoalSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Streak hero
                    streakCard

                    // Goal card
                    goalCard

                    // Reading calendar
                    readingCalendar

                    // Stats grid
                    statsGrid

                    // Vocabulary breakdown bar
                    vocabBreakdown
                }
                .padding(.top, 8)
            }
            .background(AyyatColors.background)
            .navigationTitle("Progress")
            .sheet(isPresented: $showGoalSheet) {
                GoalSheet().presentationDetents([.medium])
            }
        }
    }

    // MARK: - Daily goal

    private var goalCard: some View {
        let read = versesReadToday
        let pct  = dailyGoal > 0 ? min(1.0, Double(read) / Double(dailyGoal)) : 0
        return Button {
            showGoalSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Today's Goal", systemImage: "target")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AyyatColors.textSecondary)
                    Spacer()
                    Text(read >= dailyGoal ? "Completed " : "\(read) / \(dailyGoal) verses")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(read >= dailyGoal ? AyyatColors.mastered : AyyatColors.primary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AyyatColors.textSecondary.opacity(0.1))
                        Capsule()
                            .fill(read >= dailyGoal ? AyyatColors.mastered : AyyatColors.primary)
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(height: 8)
            }
            .padding(16)
            .bayanCard()
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var versesReadToday: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return userStore.sessions.reduce(0) { acc, session in
            guard let ended = session.endedAt,
                  cal.isDate(ended, inSameDayAs: today)
            else { return acc }
            return acc + versesInSession(session)
        }
    }

    /// Count verses for a session. Same-chapter is a simple delta; if a
    /// session crosses a chapter boundary (e.g. 2:280 → 3:5), we sum the
    /// remainder of the start chapter plus the prefix of the end chapter.
    /// Previously this returned 1 for any cross-chapter session — undercount.
    private func versesInSession(_ s: ReadingSession) -> Int {
        let (startCh, startV) = parseKey(s.startVerseKey)
        guard let endKey = s.endVerseKey else { return 1 }
        let (endCh, endV) = parseKey(endKey)
        if startCh == endCh {
            return max(1, endV - startV + 1)
        }
        let startChapterCount = quranStore.chapters.first(where: { $0.id == startCh })?.versesCount ?? startV
        let remainderOfStart = max(0, startChapterCount - startV + 1)
        let prefixOfEnd = max(0, endV)
        return max(1, remainderOfStart + prefixOfEnd)
    }

    @Environment(QuranStore.self) private var quranStore

    private func parseKey(_ key: String) -> (chapter: Int, verse: Int) {
        let parts = key.split(separator: ":")
        guard parts.count == 2,
              let ch = Int(parts[0]),
              let v = Int(parts[1])
        else { return (0, 0) }
        return (ch, v)
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 36))
                .foregroundStyle(userStore.streak.currentDays > 0 ? AyyatColors.gold : AyyatColors.unseen)

            Text("\(userStore.streak.currentDays)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(AyyatColors.primary)

            Text(userStore.streak.currentDays == 1 ? "Day Streak" : "Days Streak")
                .font(.system(size: 15))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Reading Calendar (last 28 days)

    private var readingCalendar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 4 Weeks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AyyatColors.textSecondary)

            let days = last28Days()
            let readDates = readingDates()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                // Day labels
                ForEach(Array(["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"].enumerated()), id: \.offset) { _, day in
                    Text(day)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .frame(height: 16)
                }

                // Day cells
                ForEach(days, id: \.self) { date in
                    let isRead = readDates.contains(Calendar.current.startOfDay(for: date))
                    let isToday = Calendar.current.isDateInToday(date)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isRead ? AyyatColors.primary :
                            isToday ? AyyatColors.primary.opacity(0.15) :
                            AyyatColors.textSecondary.opacity(0.08)
                        )
                        .frame(height: 28)
                        .overlay {
                            if isToday {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(AyyatColors.primary, lineWidth: 1.5)
                            }
                        }
                }
            }

            // Legend
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(AyyatColors.primary).frame(width: 10, height: 10)
                    Text("Read").font(.system(size: 10)).foregroundStyle(AyyatColors.textSecondary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(AyyatColors.textSecondary.opacity(0.08)).frame(width: 10, height: 10)
                    Text("No activity").font(.system(size: 10)).foregroundStyle(AyyatColors.textSecondary)
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
            ProgressStatCard(title: "Sessions", value: "\(userStore.streak.totalSessions)", icon: "book.closed.fill", color: AyyatColors.primary)
            ProgressStatCard(title: "Minutes", value: "\(userStore.streak.totalMinutes)", icon: "clock.fill", color: AyyatColors.learning)
            ProgressStatCard(title: "Words Known", value: "\(vocabularyStore.masteredCount + vocabularyStore.familiarCount)", icon: "character.book.closed.fill", color: AyyatColors.mastered)
            ProgressStatCard(title: "Bookmarks", value: "\(userStore.bookmarks.count)", icon: "bookmark.fill", color: AyyatColors.gold)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Vocab Breakdown

    private var vocabBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vocabulary")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AyyatColors.textSecondary)

            let total = max(vocabularyStore.totalWordsEncountered, 1)
            let mastered = vocabularyStore.masteredCount
            let familiar = vocabularyStore.familiarCount
            let learning = vocabularyStore.learningCount
            let other = total - mastered - familiar - learning

            // Stacked progress bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if mastered > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(AyyatColors.mastered)
                            .frame(width: geo.size.width * CGFloat(mastered) / CGFloat(total))
                    }
                    if familiar > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(AyyatColors.introduced)
                            .frame(width: geo.size.width * CGFloat(familiar) / CGFloat(total))
                    }
                    if learning > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(AyyatColors.learning)
                            .frame(width: geo.size.width * CGFloat(learning) / CGFloat(total))
                    }
                    if other > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(AyyatColors.unseen)
                            .frame(width: geo.size.width * CGFloat(other) / CGFloat(total))
                    }
                }
            }
            .frame(height: 12)

            // Legend
            HStack(spacing: 14) {
                vocabLegend(color: AyyatColors.mastered, label: "Mastered", count: mastered)
                vocabLegend(color: AyyatColors.introduced, label: "Familiar", count: familiar)
                vocabLegend(color: AyyatColors.learning, label: "Learning", count: learning)
                vocabLegend(color: AyyatColors.unseen, label: "New", count: other)
            }
            .font(.system(size: 11))

            Text("\(total) total words encountered")
                .font(.system(size: 12))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .padding(16)
        .bayanCard()
        .padding(.horizontal, 16)
    }

    private func vocabLegend(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)").fontWeight(.medium).foregroundStyle(AyyatColors.textPrimary)
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
                .foregroundStyle(AyyatColors.textPrimary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .bayanCard()
    }
}

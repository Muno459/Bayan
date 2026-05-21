import WidgetKit
import SwiftUI

/// Home-screen widget showing today's ayah of the day.
/// Reads from the App Group container — the app refreshes the shared
/// values when the user opens it and `DailyAyahCard` fetches the day's
/// verse.
struct DailyAyahWidget: Widget {
    let kind = "DailyAyahWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyAyahProvider()) { entry in
            DailyAyahWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.36, blue: 0.275),  // #0E5C46
                            Color(red: 0.024, green: 0.169, blue: 0.133),  // #062B22
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Ayah of the Day")
        .description("A fresh verse from the Quran each day, with translation.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline entry

struct DailyAyahEntry: TimelineEntry {
    let date: Date
    let verseKey: String
    let arabic: String
    let english: String
}

struct DailyAyahProvider: TimelineProvider {

    func placeholder(in context: Context) -> DailyAyahEntry {
        DailyAyahEntry(
            date: .now,
            verseKey: "55:13",
            arabic: "فَبِأَىِّ ءَالَآءِ رَبِّكُمَا تُكَذِّبَانِ",
            english: "So which of the favors of your Lord would you deny?"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyAyahEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyAyahEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh at midnight so the widget cycles to the next day's ayah.
        let nextMidnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(60 * 60 * 6)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> DailyAyahEntry {
        if let cached = AyyatSharedStorage.readDailyAyah() {
            return DailyAyahEntry(
                date: .now,
                verseKey: cached.verseKey,
                arabic: cached.arabic,
                english: cached.english
            )
        }
        // No cached ayah yet (fresh install or app never opened). Show a
        // gentle fallback.
        return DailyAyahEntry(
            date: .now,
            verseKey: "55:13",
            arabic: "فَبِأَىِّ ءَالَآءِ رَبِّكُمَا تُكَذِّبَانِ",
            english: "So which of the favors of your Lord would you deny?"
        )
    }
}

// MARK: - View

struct DailyAyahWidgetView: View {
    let entry: DailyAyahEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        case .systemLarge:  largeView
        default:            mediumView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            Spacer(minLength: 0)
            Text(entry.arabic)
                .font(.system(size: 14))
                .lineLimit(4)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .rightToLeft)
                .foregroundStyle(.white)
            Text(entry.verseKey)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            Text(entry.arabic)
                .font(.system(size: 16))
                .lineLimit(3)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.layoutDirection, .rightToLeft)
                .foregroundStyle(.white)
            if !entry.english.isEmpty {
                Text(entry.english)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.78))
            }
            HStack {
                Spacer()
                Text(entry.verseKey)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            label
            Spacer(minLength: 0)
            Text(entry.arabic)
                .font(.system(size: 22))
                .lineSpacing(6)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.layoutDirection, .rightToLeft)
                .foregroundStyle(.white)
            if !entry.english.isEmpty {
                Text(entry.english)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text(entry.verseKey)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("AYAH OF THE DAY")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

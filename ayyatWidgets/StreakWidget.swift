import WidgetKit
import SwiftUI

/// Tiny streak widget — shows current consecutive reading days.
struct StreakWidget: Widget {
    let kind = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            StreakWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.831, green: 0.647, blue: 0.455),  // #D4A574
                            Color(red: 0.624, green: 0.439, blue: 0.243),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Reading streak")
        .description("Glanceable streak counter for your daily Quran reading.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct StreakEntry: TimelineEntry {
    let date: Date
    let days: Int
}

struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry { .init(date: .now, days: 7) }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        completion(.init(date: .now, days: AyyatSharedStorage.readStreakDays()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        let entry = StreakEntry(date: .now, days: AyyatSharedStorage.readStreakDays())
        let next = Date().addingTimeInterval(60 * 30)  // refresh every 30 min
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct StreakWidgetView: View {
    let entry: StreakEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:    accessoryCircular
        case .accessoryRectangular: accessoryRectangular
        case .accessoryInline:      accessoryInline
        default:                    home
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("STREAK")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
            }
            .foregroundStyle(.white.opacity(0.8))

            Spacer(minLength: 0)

            Text("\(entry.days)")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            Text(entry.days == 1 ? "day" : "days")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "flame.fill").font(.system(size: 10))
                Text("\(entry.days)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var accessoryRectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.days) day streak")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("ayyat · reading")
                    .font(.system(size: 11))
                    .opacity(0.7)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessoryInline: some View {
        Label("\(entry.days)-day Quran streak", systemImage: "flame.fill")
    }
}

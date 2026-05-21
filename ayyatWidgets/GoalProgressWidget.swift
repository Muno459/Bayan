import WidgetKit
import SwiftUI

/// Small widget showing today's verses-read vs daily goal.
struct GoalProgressWidget: Widget {
    let kind = "GoalProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GoalProvider()) { entry in
            GoalProgressWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.965, green: 0.957, blue: 0.917)  // #F8F4EA
                }
        }
        .configurationDisplayName("Today's goal")
        .description("Verses read today vs your daily reading goal.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

struct GoalEntry: TimelineEntry {
    let date: Date
    let target: Int
    let versesToday: Int

    var pct: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(versesToday) / Double(target))
    }
}

struct GoalProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoalEntry {
        .init(date: .now, target: 10, versesToday: 4)
    }
    func getSnapshot(in context: Context, completion: @escaping (GoalEntry) -> Void) {
        let g = AyyatSharedStorage.readGoal()
        completion(.init(date: .now, target: max(1, g.target), versesToday: g.versesToday))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalEntry>) -> Void) {
        let g = AyyatSharedStorage.readGoal()
        let entry = GoalEntry(date: .now, target: max(1, g.target), versesToday: g.versesToday)
        let next = Date().addingTimeInterval(60 * 30)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct GoalProgressWidgetView: View {
    let entry: GoalEntry
    @Environment(\.widgetFamily) private var family

    private let emerald = Color(red: 0.055, green: 0.36, blue: 0.275)

    var body: some View {
        switch family {
        case .accessoryCircular: accessoryCircular
        case .accessoryInline:   accessoryInline
        default:                 home
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            ProgressView(value: entry.pct) {
                Image(systemName: "target").font(.system(size: 10))
            } currentValueLabel: {
                Text("\(entry.versesToday)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .progressViewStyle(.circular)
        }
    }

    private var accessoryInline: some View {
        Label("\(entry.versesToday) / \(entry.target) verses today", systemImage: "target")
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .bold))
                Text("TODAY'S GOAL")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
            }
            .foregroundStyle(emerald.opacity(0.7))

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .stroke(emerald.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: entry.pct)
                    .stroke(emerald, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(entry.versesToday)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(emerald)
                    Text("/ \(entry.target)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(emerald.opacity(0.7))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

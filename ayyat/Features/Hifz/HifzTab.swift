import SwiftUI

/// Top-level Hifz tab. Only mounted in `ContentView` once `HifzStore.isUnlocked`
/// is true — fresh installs see only Read / Learn / Progress / Settings.
struct HifzTab: View {
    @Environment(HifzStore.self) private var hifz
    @Environment(QuranStore.self) private var quranStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if hifz.allVerses.isEmpty {
                        empty
                    } else {
                        if !hifz.dueToday.isEmpty {
                            section(
                                title: "Due today",
                                subtitle: "Recall these to keep your streak.",
                                verses: hifz.dueToday,
                                accent: AyyatColors.gold
                            )
                        }

                        let pending = hifz.inProgress.filter { !$0.isDueToday() }
                        if !pending.isEmpty {
                            section(
                                title: "In progress",
                                subtitle: "Not due yet — the next review is scheduled.",
                                verses: pending,
                                accent: AyyatColors.primary
                            )
                        }

                        if !hifz.memorized.isEmpty {
                            section(
                                title: "Memorized",
                                subtitle: "Three consecutive blind passes. Keep revisiting to retain.",
                                verses: hifz.memorized,
                                accent: AyyatColors.mastered
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(AyyatColors.background)
            .navigationTitle("Hifz")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow
            Text("Memorize verse by verse. Familiar words are hidden first; recite the blanks back to ayyat — Tarteel grades you on-device.")
                .font(.system(size: 13))
                .foregroundStyle(AyyatColors.textSecondary)
                .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            statChip(value: "\(hifz.dueToday.count)", label: "due", color: AyyatColors.gold)
            statChip(value: "\(hifz.inProgress.count)", label: "in progress", color: AyyatColors.primary)
            statChip(value: "\(hifz.memorized.count)", label: "memorized", color: AyyatColors.mastered)
        }
    }

    private func statChip(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.08))
        )
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 36))
                .foregroundStyle(AyyatColors.primary.opacity(0.7))
            Text("Pick your first verse")
                .font(.system(size: 18, weight: .semibold))
            Text("Tap \"Memorize\" under any verse in Read to add it to your queue.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(AyyatColors.textSecondary)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AyyatColors.primary.opacity(0.05))
        )
    }

    private func section(title: String, subtitle: String, verses: [HifzState], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            VStack(spacing: 8) {
                ForEach(verses) { state in
                    NavigationLink {
                        HifzSessionView(verseKey: state.verseKey)
                    } label: {
                        row(for: state, accent: accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(for state: HifzState, accent: Color) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(chapterName(state.chapterId) + " · " + state.verseKey)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                Text(state.statusLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            Spacer()
            revealMeter(state.revealLevel)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AyyatColors.readerBackground)
        )
    }

    private func revealMeter(_ level: Double) -> some View {
        // Reveal level (0 = blank, 1 = full text). Matches the
        // 'Reveal %' label inside HifzSessionView so the two views stay
        // consistent — previously this showed "% hidden" which was the
        // inverse and confused users switching between screens.
        ZStack {
            Circle().stroke(AyyatColors.textSecondary.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: level)
                .stroke(AyyatColors.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 30, height: 30)
        .overlay(
            Text("\(Int(level * 100))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(AyyatColors.textSecondary)
                .monospacedDigit()
        )
    }

    private func chapterName(_ id: Int) -> String {
        quranStore.chapters.first(where: { $0.id == id })?.nameSimple ?? "Surah \(id)"
    }
}

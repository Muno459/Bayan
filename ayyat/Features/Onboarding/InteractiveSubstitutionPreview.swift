import SwiftUI

/// A live, animated demo of progressive substitution.
/// The slider auto-advances 0 → 1 → 0 and the sample verse swaps English
/// words for Arabic in lockstep — first the common ones, then everything.
/// Users can also drag the slider themselves to feel the mechanic.
struct InteractiveSubstitutionPreview: View {
    @State private var level: Double = 0
    @State private var direction: Double = 1
    @State private var userInteracted = false
    @State private var task: Task<Void, Never>?

    /// Sample: Surah Al-Fatihah verse 1 (Bismillah).
    /// The Quran has 4 Arabic words here — مَا ("of") doesn't exist as its
    /// own token, the genitive case is folded into بِسْمِ. So we present 4
    /// proper word pairs, no orphan blanks. Each has a "difficulty" 0..1
    /// mimicking the real engine's mastery-driven hide order.
    private static let words: [(en: String, ar: String, score: Double)] = [
        ("In the name of",       "بِسْمِ",         0.40),
        ("Allah",                "ٱللَّهِ",         0.05),
        ("the Most Gracious",    "ٱلرَّحْمَـٰنِ",   0.10),
        ("the Most Merciful",    "ٱلرَّحِيمِ",     0.10),
    ]

    var body: some View {
        VStack(spacing: 18) {
            WrappingHStack(alignment: .center, spacing: 6) {
                ForEach(Array(Self.words.enumerated()), id: \.offset) { _, w in
                    wordTile(w)
                }
            }
            .lineSpacing(8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(AyyatColors.readerBackground)
            )

            VStack(spacing: 4) {
                Slider(value: $level, in: 0...1) { editing in
                    if editing { userInteracted = true; task?.cancel() }
                }
                .tint(AyyatColors.primary)

                HStack {
                    Text("All English")
                    Spacer()
                    Text("\(Int(level * 100))% Arabic")
                        .foregroundStyle(AyyatColors.primary)
                        .monospacedDigit()
                    Spacer()
                    Text("All Arabic")
                }
                .font(.system(size: 11))
                .foregroundStyle(AyyatColors.textSecondary)
            }
        }
        .padding(.horizontal, 24)
        .onAppear { startAutoplay() }
        .onDisappear { task?.cancel() }
    }

    private func wordTile(_ w: (en: String, ar: String, score: Double)) -> some View {
        // The word shows as Arabic once the slider passes its score.
        let showArabic = level >= w.score
        return Group {
            if showArabic {
                Text(w.ar)
                    .font(.system(size: 22))
                    .environment(\.locale, Locale(identifier: "ar"))
                    .foregroundStyle(AyyatColors.primary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AyyatColors.primary.opacity(0.1))
                    )
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(w.en)
                    .font(.system(size: 17))
                    .foregroundStyle(AyyatColors.textPrimary)
                    .transition(.opacity)
            }
        }
        .id(w.en + "-" + (showArabic ? "ar" : "en"))
        .animation(.easeInOut(duration: 0.35), value: showArabic)
    }

    private func startAutoplay() {
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled, !userInteracted {
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
                guard !userInteracted else { return }
                level += direction * 0.005
                if level >= 1.0 {
                    level = 1.0; direction = -1
                    try? await Task.sleep(for: .seconds(1.2))
                    if Task.isCancelled { return }
                }
                if level <= 0.0 {
                    level = 0.0; direction =  1
                    try? await Task.sleep(for: .seconds(1.2))
                    if Task.isCancelled { return }
                }
            }
        }
    }
}

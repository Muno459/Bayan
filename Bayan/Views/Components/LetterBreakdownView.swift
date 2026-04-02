import SwiftUI

/// Displays an Arabic word broken down letter by letter.
/// Each letter shows its Arabic form and English name.
/// Helps beginners learn to read Arabic script.
struct LetterBreakdownView: View {
    let arabicText: String
    @State private var highlightedIndex: Int?

    private var breakdown: [LetterBreakdown] {
        ArabicLetterData.breakdownWord(arabicText)
    }

    var body: some View {
        if !breakdown.isEmpty {
            VStack(spacing: 10) {
                // Section header
                HStack {
                    Image(systemName: "character.magnify")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.primary)
                    Text("Letters in this word")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BayanColors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                // Letter grid
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(breakdown.enumerated()), id: \.element.id) { index, letter in
                            VStack(spacing: 4) {
                                // Arabic letter with diacritics
                                Text(letter.display)
                                    .font(.system(size: 28, design: .serif))
                                    .foregroundStyle(
                                        highlightedIndex == index
                                            ? BayanColors.primary
                                            : BayanColors.textPrimary
                                    )
                                    .frame(minWidth: 36, minHeight: 40)

                                // Letter name
                                Text(letter.letterName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(BayanColors.textSecondary)

                                // Diacritics info
                                if !letter.diacritics.isEmpty {
                                    Text(letter.diacritics.first ?? "")
                                        .font(.system(size: 8))
                                        .foregroundStyle(BayanColors.primary.opacity(0.6))
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        highlightedIndex == index
                                            ? BayanColors.primary.opacity(0.08)
                                            : BayanColors.textSecondary.opacity(0.04)
                                    )
                            )
                            .onTapGesture {
                                Haptics.selection()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    highlightedIndex = index
                                }
                                // Auto-clear after 1.5s
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    withAnimation { highlightedIndex = nil }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(BayanColors.textSecondary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(BayanColors.textSecondary.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
        }
    }
}

import SwiftUI

/// Shows a brief celebration overlay when user hits a vocabulary milestone.
struct MilestoneOverlay: View {
    let milestone: VocabularyMilestone
    @State private var isVisible = true
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0

    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                Image(systemName: milestone.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(BayanColors.gold)

                Text(milestone.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BayanColors.textPrimary)

                Text(milestone.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(BayanColors.textSecondary)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 20)
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                Haptics.success()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    scale = 1.0
                    opacity = 1.0
                }
                // Auto-dismiss
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.3)) {
                        opacity = 0
                        scale = 0.8
                    }
                    try? await Task.sleep(for: .seconds(0.3))
                    isVisible = false
                }
            }
        }
    }
}

struct VocabularyMilestone: Equatable {
    let title: String
    let subtitle: String
    let icon: String

    static func check(oldCount: Int, newCount: Int) -> VocabularyMilestone? {
        let milestones = [
            (1, "First Word!", "You learned your first Arabic word", "star.fill"),
            (5, "5 Words!", "You're building your vocabulary", "flame.fill"),
            (10, "10 Words!", "Double digits", "sparkles"),
            (25, "25 Words!", "A growing vocabulary", "book.fill"),
            (50, "50 Words!", "Halfway to 100", "medal.fill"),
            (100, "100 Words!", "Mashallah, impressive progress", "trophy.fill"),
        ]

        for (count, title, subtitle, icon) in milestones {
            if oldCount < count && newCount >= count {
                return VocabularyMilestone(title: title, subtitle: subtitle, icon: icon)
            }
        }
        return nil
    }
}

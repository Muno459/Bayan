import SwiftUI

/// First-launch onboarding explaining the progressive substitution concept.
struct OnboardingView: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @AppStorage("hasCompletedOnboarding") private var hasCompleted = false
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 1: Welcome
            onboardingPage(
                icon: "book.fill",
                iconColor: BayanColors.primary,
                title: "Welcome to Bayan",
                subtitle: "Learn Quranic Arabic naturally",
                body: "Bayan helps you understand the Quran by gradually introducing Arabic words into your reading. No prior Arabic knowledge needed."
            )
            .tag(0)

            // Page 2: How it works
            onboardingPage(
                icon: "arrow.triangle.swap",
                iconColor: BayanColors.gold,
                title: "Progressive Substitution",
                subtitle: "English becomes Arabic over time",
                body: "You start reading in English. As you encounter words repeatedly, they are replaced with their original Arabic script. Tap any Arabic word to see its meaning and hear its pronunciation."
            )
            .tag(1)

            // Page 3: Set level
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 52))
                    .foregroundStyle(BayanColors.primary)

                Text("Set Your Starting Level")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BayanColors.textPrimary)

                Text("How much Quranic Arabic do you already know?")
                    .font(.system(size: 15))
                    .foregroundStyle(BayanColors.textSecondary)

                VStack(spacing: 12) {
                    levelButton(title: "Complete Beginner", subtitle: "I read the Quran only in English", level: 0.0)
                    levelButton(title: "Know Some Words", subtitle: "I recognize Allah, Bismillah, Rahman", level: 0.3)
                    levelButton(title: "Intermediate", subtitle: "I can read some Arabic script", level: 0.6)
                    levelButton(title: "Advanced", subtitle: "I want mostly Arabic", level: 0.9)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(BayanColors.background)
    }

    private func onboardingPage(
        icon: String, iconColor: Color,
        title: String, subtitle: String, body: String
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(iconColor)
                .padding(.bottom, 8)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(BayanColors.textPrimary)
            Text(subtitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BayanColors.primary)
            Text(body)
                .font(.system(size: 15))
                .foregroundStyle(BayanColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineSpacing(4)
            Spacer()
            Button {
                withAnimation { currentPage += 1 }
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(BayanColors.primary))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func levelButton(title: String, subtitle: String, level: Double) -> some View {
        Button {
            vocabularyStore.substitutionLevel = level
            hasCompleted = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BayanColors.textPrimary)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(BayanColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(BayanColors.textSecondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)).shadow(color: .black.opacity(0.05), radius: 6, y: 2))
        }
    }
}

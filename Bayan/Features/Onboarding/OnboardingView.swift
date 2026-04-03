import SwiftUI

/// First-launch onboarding explaining progressive substitution
/// with Islamic context for learning Arabic.
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

            // Page 2: The reward of struggling
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "star.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(BayanColors.gold)

                Text("Double the Reward")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BayanColors.textPrimary)

                // Hadith
                VStack(spacing: 12) {
                    Text("The Prophet \u{FDFA} said:")
                        .font(.system(size: 14))
                        .foregroundStyle(BayanColors.textSecondary)

                    Text("\u{201C}The one who is proficient in reciting the Quran will be with the noble, obedient angels, and the one who recites the Quran while struggling with it will have a double reward.\u{201D}")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(BayanColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 24)

                    Text("Sahih al-Bukhari 4937, Sahih Muslim 798")
                        .font(.system(size: 12))
                        .foregroundStyle(BayanColors.textSecondary)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BayanColors.gold.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BayanColors.gold.opacity(0.15)))
                )
                .padding(.horizontal, 24)

                Text("Every effort you make to read Arabic is rewarded, even if it feels difficult at first.")
                    .font(.system(size: 14))
                    .foregroundStyle(BayanColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

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
            .tag(1)

            // Page 3: How it works
            onboardingPage(
                icon: "arrow.triangle.swap",
                iconColor: BayanColors.primary,
                title: "Progressive Substitution",
                subtitle: "English becomes Arabic over time",
                body: "You start reading in English. As you encounter words repeatedly, they are replaced with their original Arabic script. Tap any Arabic word to hear its pronunciation and see its meaning."
            )
            .tag(2)

            // Page 4: Choose your path
            VStack(spacing: 20) {
                Spacer()

                Text("Choose Your Path")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BayanColors.textPrimary)

                Text("How would you like to learn?")
                    .font(.system(size: 15))
                    .foregroundStyle(BayanColors.textSecondary)

                VStack(spacing: 14) {
                    // Option 1: Arabic Script (recommended)
                    Button {
                        vocabularyStore.useTransliteration = false
                        withAnimation { currentPage += 1 }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Learn Arabic Script")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(BayanColors.textPrimary)
                                Spacer()
                                Text("Recommended")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(BayanColors.mastered)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(BayanColors.mastered.opacity(0.1)))
                            }
                            Text("English words gradually become Arabic script. You learn to read the Quran in its original form.")
                                .font(.system(size: 13))
                                .foregroundStyle(BayanColors.textSecondary)
                                .lineSpacing(2)
                            // Preview
                            HStack(spacing: 4) {
                                Text("In the name of")
                                    .font(.system(size: 14))
                                    .foregroundStyle(BayanColors.textSecondary)
                                Text("ٱللَّهِ")
                                    .font(.system(size: 18))
                                    .foregroundStyle(BayanColors.primary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(BayanColors.primary.opacity(0.2)))
                        )
                    }

                    // Option 2: Transliteration
                    Button {
                        vocabularyStore.useTransliteration = true
                        withAnimation { currentPage += 1 }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Learn with Transliteration")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(BayanColors.textPrimary)
                            Text("English words become phonetic pronunciation guides. Helpful if you cannot read Arabic letters yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(BayanColors.textSecondary)
                                .lineSpacing(2)
                            // Preview
                            HStack(spacing: 4) {
                                Text("In the name of")
                                    .font(.system(size: 14))
                                    .foregroundStyle(BayanColors.textSecondary)
                                Text("l-lahi")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(BayanColors.primary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                        )
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .tag(3)

            // Page 5: Set level
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 52))
                    .foregroundStyle(BayanColors.primary)

                Text("Set Your Starting Level")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BayanColors.textPrimary)

                Text("How much do you already know?")
                    .font(.system(size: 15))
                    .foregroundStyle(BayanColors.textSecondary)

                VStack(spacing: 12) {
                    levelButton(title: "Complete Beginner", subtitle: "Start with all English", level: 0.0)
                    levelButton(title: "Know Some Words", subtitle: "Allah, Bismillah, Rahman", level: 0.3)
                    levelButton(title: "Intermediate", subtitle: "I know many Quranic words", level: 0.6)
                    levelButton(title: "Advanced", subtitle: "Show me mostly Arabic", level: 0.9)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .tag(4)
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

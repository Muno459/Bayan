import SwiftUI

/// Three-page one-time welcome shown to TestFlight beta testers on
/// the first launch of the beta build:
///   Page 1: thanks + which feedback shaped this build
///   Page 2: Quran 2:271 (silent charity)
///   Page 3: hadith of guidance (Sahih Muslim 1893)
///
/// Persists a UserDefaults flag so the sheet never appears again on
/// this device.
struct BetaWelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var iconPulse = false

    private static let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                page1.tag(0)
                page2.tag(1)
                page3.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            pageDots
                .padding(.bottom, 18)

            primaryButton
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .background(AyyatColors.background.ignoresSafeArea())
        .onAppear { iconPulse = true }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Page 1: thank-you + feedback acknowledgement

    private var page1: some View {
        VStack(spacing: 0) {
            brandIcon
                .padding(.top, 50)
                .padding(.bottom, 24)

            Text("آيات")
                .font(.custom("Amiri", size: 44))
                .foregroundStyle(AyyatColors.primary)
                .padding(.bottom, 6)

            Text("Thank you for beta testing")
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AyyatColors.textSecondary)
                .textCase(.uppercase)
                .padding(.bottom, 10)

            Text("Your feedback shaped this build")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(AyyatColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)

            Text("All feedback came in anonymously. No name attached, no recognition asked for, just sincere observations sent in the quiet.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
                .padding(.bottom, 26)

            VStack(spacing: 14) {
                row(
                    icon: "checkmark.seal.fill",
                    title: "What changed this round",
                    body: "We no longer use the Quran.com word-by-word data for our main engine. We built our own in-house per-word data using Saheeh International, which fixes many of the problems you reported. We still use Quran.com data for other things."
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Page 2: Quran 2:271 (silent charity)

    private var page2: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            Text("Quran")
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AyyatColors.gold)
                .textCase(.uppercase)
                .padding(.bottom, 24)

            // Arabic ayah, large.
            Text("إِن تُبْدُوا۟ ٱلصَّدَقَـٰتِ فَنِعِمَّا هِىَ ۖ وَإِن تُخْفُوهَا وَتُؤْتُوهَا ٱلْفُقَرَآءَ فَهُوَ خَيْرٌۭ لَّكُمْ ۚ وَيُكَفِّرُ عَنكُم مِّن سَيِّـَٔاتِكُمْ ۗ وَٱللَّهُ بِمَا تَعْمَلُونَ خَبِيرٌۭ")
                .font(.custom("Amiri", size: 22))
                .foregroundStyle(AyyatColors.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(10)
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
                .environment(\.layoutDirection, .rightToLeft)

            VStack(spacing: 16) {
                Text("\"If you disclose your charitable expenditures, they are good; but if you conceal them and give them to the poor, it is better for you, and He will remove from you some of your misdeeds [thereby]. And Allāh, of what you do, is [fully] Aware.\"")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AyyatColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 22)

                Text("Quran 2:271")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        Capsule().fill(AyyatColors.primary.opacity(0.08))
                    )
            }
            .padding(.bottom, 20)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Page 3: hadith of guidance

    private var page3: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            Text("Hadith")
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AyyatColors.gold)
                .textCase(.uppercase)
                .padding(.bottom, 24)

            // Arabic matn, large.
            Text("مَنْ دَلَّ عَلَى خَيْرٍ فَلَهُ مِثْلُ أَجْرِ فَاعِلِهِ")
                .font(.custom("Amiri", size: 32))
                .foregroundStyle(AyyatColors.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(10)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .environment(\.layoutDirection, .rightToLeft)

            // English meaning, attributed.
            VStack(spacing: 16) {
                Text("The Messenger of Allah ﷺ said:")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text("\"One who guides to something good has a reward similar to that of its doer.\"")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(AyyatColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 24)

                Text("Sahih Muslim 1893")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        Capsule().fill(AyyatColors.primary.opacity(0.08))
                    )
            }
            .padding(.bottom, 28)

            // Closing line tying it back.
            Text("Whatever benefit this app brings to anyone learning the Quran is written in your favour too, biidhnillāh. Jazākum Allāhu khairan.")
                .font(.system(size: 13))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Pieces

    private var brandIcon: some View {
        ZStack {
            Circle()
                .fill(AyyatColors.primary.opacity(0.10))
                .frame(width: 120, height: 120)
                .scaleEffect(iconPulse ? 1.15 : 1.0)
                .opacity(iconPulse ? 0.0 : 0.6)
                .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false), value: iconPulse)
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AyyatColors.primary)
                    .frame(width: 96, height: 96)
                    .shadow(color: AyyatColors.primary.opacity(0.35), radius: 18, y: 8)
                OctagramShape()
                    .fill(AyyatColors.cardBackground)
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(AyyatColors.gold)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func row(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(AyyatColors.primary.opacity(0.10))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AyyatColors.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.pageCount, id: \.self) { i in
                Circle()
                    .fill(page == i ? AyyatColors.primary : AyyatColors.primary.opacity(0.20))
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }

    private var primaryButton: some View {
        let isLast = page == Self.pageCount - 1
        return Button {
            if isLast {
                // Versioned key — each build with material changes
                // increments the suffix so existing testers see the
                // welcome sheet again for the new round.
                UserDefaults.standard.set(true, forKey: "hasSeenBetaWelcome_v21")
                Haptics.light()
                dismiss()
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                Haptics.light()
            }
        } label: {
            Text(isLast ? "Bismillāh, let's keep going" : "Continue")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AyyatColors.primary)
                )
        }
        .buttonStyle(.plain)
    }
}

/// 8-pointed star, same geometry as the app icon's central motif.
private struct OctagramShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.7071
        let points = 8
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outer : inner
            let angle = (CGFloat(i) * .pi / CGFloat(points)) - .pi / 2
            let x = center.x + r * cos(angle)
            let y = center.y + r * sin(angle)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

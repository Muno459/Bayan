import SwiftUI

/// Apple-style shimmer placeholder. Wrap any view to give it a moving
/// gradient highlight while content loads.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.55), location: 0.45),
                                .init(color: .white.opacity(0.85), location: 0.5),
                                .init(color: .white.opacity(0.55), location: 0.55),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 1.6)
                        .offset(x: -geo.size.width * 0.8 + geo.size.width * 1.6 * phase)
                        .mask(content)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            phase = 1
                        }
                    }
                }
            }
    }
}

extension View {
    /// Adds a moving shimmer highlight while `active` is true.
    /// Use behind ProgressView for "real" content placeholders.
    func shimmer(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

/// Tinted rectangle used as a content placeholder.
struct SkeletonBar: View {
    let width: CGFloat?
    let height: CGFloat

    init(width: CGFloat? = nil, height: CGFloat = 14) {
        self.width = width
        self.height = height
    }

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.4)
            .fill(AyyatColors.textSecondary.opacity(0.12))
            .frame(width: width, height: height)
    }
}

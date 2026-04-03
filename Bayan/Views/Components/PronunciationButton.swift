import SwiftUI

/// Hold-to-record pronunciation practice button.
/// Press and hold to record, release to check pronunciation.
struct PronunciationButton: View {
    let expectedArabic: String
    @State private var checker = PronunciationChecker()
    @State private var isHolding = false

    var body: some View {
        VStack(spacing: 6) {
            switch checker.state {
            case .idle, .loading:
                // Hold to record
                Button {} label: {
                    Label(
                        isHolding ? "Listening..." : "Hold to Pronounce",
                        systemImage: isHolding ? "mic.fill" : "mic"
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHolding ? .white : BayanColors.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(isHolding ? BayanColors.primary : BayanColors.primary.opacity(0.08))
                    )
                    .scaleEffect(isHolding ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHolding)
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.1)
                        .onEnded { _ in
                            Haptics.medium()
                            isHolding = true
                            Task {
                                if checker.state == .idle {
                                    await checker.loadModel()
                                }
                                checker.startRecording()
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            if isHolding {
                                isHolding = false
                                Haptics.light()
                                Task {
                                    await checker.stopRecording(expectedArabic: expectedArabic)
                                }
                            }
                        }
                )

            case .recording:
                // Show recording state (in case gesture detection is delayed)
                Button {
                    isHolding = false
                    Task {
                        await checker.stopRecording(expectedArabic: expectedArabic)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Release to check")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.red.opacity(0.8)))
                }

            case .processing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking...")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }

            case .result(let correct, _):
                HStack(spacing: 6) {
                    Image(systemName: correct ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                    Text(correct ? "Correct!" : "Try again")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                }
                .onTapGesture { checker.reset() }
                .onAppear {
                    Haptics.success()
                    // Auto-reset after 2 seconds
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        checker.reset()
                    }
                }

            case .error:
                Button { checker.reset() } label: {
                    Label("Tap to retry", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }
            }
        }
    }
}

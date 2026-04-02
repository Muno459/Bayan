import SwiftUI

/// Floating audio player bar at the bottom of the reading view
struct AudioPlayerBar: View {
    let chapterId: Int

    @Environment(AudioPlaybackManager.self) private var audioManager
    @Environment(QuranStore.self) private var quranStore

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(BayanColors.primary.opacity(0.1))

                    Rectangle()
                        .fill(BayanColors.gold)
                        .frame(width: geo.size.width * audioManager.playbackProgress)
                        .animation(.linear(duration: 0.1), value: audioManager.playbackProgress)
                }
            }
            .frame(height: 3)

            // Controls
            HStack(spacing: BayanSpacing.lg) {
                // Current verse indicator
                VStack(alignment: .leading, spacing: 2) {
                    if let verseKey = audioManager.currentVerseKey {
                        Text("Verse \(verseKey)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BayanColors.textPrimary)
                    }

                    if audioManager.isLoading {
                        Text("Loading audio...")
                            .font(.system(size: 12))
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                }

                Spacer()

                // Play/Pause
                Button {
                    if audioManager.isPlaying || audioManager.currentVerseKey != nil {
                        audioManager.togglePlayback()
                    } else {
                        Task {
                            do {
                                let audioFile = try await quranStore.fetchAudio(for: chapterId)
                                await audioManager.loadAudio(audioFile: audioFile)
                                audioManager.play()
                            } catch {
                                audioManager.error = error.localizedDescription
                            }
                        }
                    }
                } label: {
                    Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(BayanColors.primary)
                        .symbolRenderingMode(.hierarchical)
                }

                // Stop
                Button {
                    audioManager.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(BayanColors.textSecondary)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .padding(.horizontal, BayanSpacing.md)
            .padding(.vertical, BayanSpacing.sm)
        }
        .background(.ultraThinMaterial)
    }
}

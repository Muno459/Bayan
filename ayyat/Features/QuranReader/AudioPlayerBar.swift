import SwiftUI

/// Floating audio player bar with progress, play/pause, skip, and speed controls.
struct AudioPlayerBar: View {
    let chapterId: Int

    @Environment(AudioPlaybackManager.self) private var audioManager
    @Environment(QuranStore.self) private var quranStore
    @Environment(SettingsManager.self) private var settings
    @State private var playbackSpeed: Float = 1.0

    // Wider speed range. Reciter audio at 2× still reads cleanly because
    // Quranic recitation has long mads and clear consonants; 2× is closer
    // to "active listening" speed than rushed.
    private let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(AyyatColors.primary.opacity(0.1))
                    Rectangle().fill(AyyatColors.gold)
                        .frame(width: geo.size.width * audioManager.playbackProgress)
                        .animation(.linear(duration: 0.1), value: audioManager.playbackProgress)
                }
            }
            .frame(height: 3)

            HStack(spacing: 16) {
                // Verse info
                VStack(alignment: .leading, spacing: 2) {
                    if let key = audioManager.currentVerseKey {
                        Text("Verse \(key)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AyyatColors.textPrimary)
                    }
                    if audioManager.isLoading {
                        Text("Loading...")
                            .font(.system(size: 11))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }
                .frame(minWidth: 60, alignment: .leading)

                Spacer()

                // Speed button
                Button {
                    cycleSpeed()
                } label: {
                    Text("\(String(format: "%.1f", playbackSpeed))x")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AyyatColors.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AyyatColors.primary.opacity(0.1)))
                }

                // Previous verse
                Button {
                    Haptics.selection()
                    audioManager.skipToPreviousVerse()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AyyatColors.textPrimary)
                }

                // Play/Pause
                Button {
                    if audioManager.isReady {
                        audioManager.togglePlayback()
                    } else {
                        Task {
                            do {
                                let audioFile = try await quranStore.fetchAudio(for: chapterId, reciterId: settings.selectedReciterId)
                                await audioManager.loadAudio(audioFile: audioFile, chapterId: chapterId)
                                audioManager.play()
                            } catch {
                                audioManager.error = error.localizedDescription
                            }
                        }
                    }
                } label: {
                    Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(AyyatColors.primary)
                        .symbolRenderingMode(.hierarchical)
                }

                // Next verse
                Button {
                    Haptics.selection()
                    audioManager.skipToNextVerse()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AyyatColors.textPrimary)
                }

                // Stop
                Button {
                    audioManager.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func cycleSpeed() {
        if let idx = speeds.firstIndex(of: playbackSpeed) {
            let nextIdx = (idx + 1) % speeds.count
            playbackSpeed = speeds[nextIdx]
        } else {
            playbackSpeed = 1.0
        }
        audioManager.setPlaybackSpeed(playbackSpeed)
    }
}

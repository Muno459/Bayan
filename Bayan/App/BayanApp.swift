import SwiftUI

@main
struct BayanApp: App {
    @State private var quranStore = QuranStore()
    @State private var vocabularyStore = VocabularyStore()
    @State private var audioManager = AudioPlaybackManager()
    @State private var settingsManager = SettingsManager()
    @State private var userStore = UserStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environment(quranStore)
                    .environment(vocabularyStore)
                    .environment(audioManager)
                    .environment(settingsManager)
                    .environment(userStore)
            } else {
                OnboardingView()
                    .environment(vocabularyStore)
            }
        }
    }
}

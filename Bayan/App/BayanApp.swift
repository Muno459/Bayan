import SwiftUI

@main
struct BayanApp: App {
    @State private var quranStore = QuranStore()
    @State private var vocabularyStore = VocabularyStore()
    @State private var audioManager = AudioPlaybackManager()
    @State private var settingsManager = SettingsManager()
    @State private var userStore = UserStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(quranStore)
                .environment(vocabularyStore)
                .environment(audioManager)
                .environment(settingsManager)
                .environment(userStore)
        }
    }
}

import SwiftUI

@main
struct AyyatApp: App {
    @State private var quranStore = QuranStore()
    @State private var vocabularyStore = VocabularyStore()
    @State private var audioManager = AudioPlaybackManager()
    @State private var settingsManager = SettingsManager()
    @State private var userStore: UserStore
    @State private var oidcAuth: OIDCAuthService
    @State private var hifzStore = HifzStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        // Wire the user store ↔ user-API client *synchronously* in init,
        // before any sheet or session has a chance to fire. If we defer
        // this into a .task (the previous approach), a cold launch with
        // a stored access token would try to sync bookmarks while
        // userStore.userAPI was still nil, and the request would be
        // silently dropped via the `guard let api = userAPI` short-circuit.
        let auth = OIDCAuthService()
        let store = UserStore()
        store.userAPI = UserAPIClient(auth: auth)
        _oidcAuth = State(initialValue: auth)
        _userStore = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environment(quranStore)
                    .environment(vocabularyStore)
                    .environment(audioManager)
                    .environment(settingsManager)
                    .environment(userStore)
                    .environment(oidcAuth)
                    .environment(hifzStore)
                    // Apply the user's Light/System/Dark preference globally.
                    // `.system` evaluates to nil → SwiftUI defers to the OS.
                    .preferredColorScheme(settingsManager.darkModeOverride.colorScheme)
                    .task(priority: .background) {
                        // Preload pronunciation model in low-priority background
                        // Won't block UI, but ready faster when user needs it
                        try? await Task.sleep(for: .seconds(2)) // Let UI settle first
                        SharedPronunciationChecker.checker.preloadModel()
                    }
                    // Safety net: if ASWebAuthenticationSession misses the
                    // custom-scheme bridge (or iOS opens the universal-link
                    // version of /oauth/callback through the app instead of
                    // the in-session Safari), this catches the URL and
                    // hands the auth code over to OIDCAuthService.
                    .onOpenURL { url in
                        Task {
                            await oidcAuth.handleExternalCallback(url)
                        }
                    }
                    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                        if let url = activity.webpageURL {
                            Task {
                                await oidcAuth.handleExternalCallback(url)
                            }
                        }
                    }
            } else {
                OnboardingView()
                    .environment(vocabularyStore)
            }
        }
    }
}

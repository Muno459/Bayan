import SwiftUI

/// Daily-ayah hero card.
/// Renders the day's verse through the substitution engine so the user
/// gets a learning moment every time they open the app. Cached
/// per-day so the same verse shows for a whole day.
///
/// Loading is invisible by design: a cached verse renders synchronously
/// from `init`, the network fetch only kicks in on a fresh day. No
/// spinner ever blocks the card.
struct DailyAyahCard: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(AppNavigation.self) private var nav

    @State private var verse: Verse?

    private static let cacheKey = "ayyat_daily_ayah_v2"
    private static let cacheDateKey = "ayyat_daily_ayah_date_v2"

    init() {
        // Synchronous warm-start — pull yesterday's cached ayah out of the
        // defaults right now so the card never has to render a blank state.
        // The .task below will either keep it (if still today) or swap it.
        _verse = State(initialValue: Self.loadCached())
    }

    var body: some View {
        Button {
            // Open the verse's chapter in the Read tab. Cross-tab nav via
            // AppNavigation: flip selectedTab to .read and push the
            // chapter so the back gesture lands cleanly on the chapter list.
            guard let v = verse else { return }
            let chapterId = Int(v.verseKey.split(separator: ":").first ?? "1") ?? 1
            Haptics.light()
            nav.openInRead(chapterId: chapterId)
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await refreshIfNewDay() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            substitutionLine
            translationLine
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    AyyatColors.gold.opacity(0.18),
                    AyyatColors.primary.opacity(0.10)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(AyyatColors.primary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("AYAH OF THE DAY")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
            Spacer()
            if let key = verse?.verseKey {
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(AyyatColors.primary.opacity(0.75))
    }

    @ViewBuilder
    private var substitutionLine: some View {
        if let verse, let words = verse.words?.filter(\.isWord), !words.isEmpty {
            // Same bidi-aware layout as VerseCell so multi-line Arabic
            // runs read in natural recitation order instead of getting
            // visually scrambled across wrap boundaries.
            let bidiOn = settings.arabicMixedDirection == .rtl &&
                         !vocabularyStore.useTransliteration
            WrappingHStack(alignment: .leading, spacing: 5, bidiAware: bidiOn) {
                ForEach(words) { word in
                    let display = vocabularyStore.displayMode(for: word)
                    let isArabic: Bool = {
                        if case .english = display { return false }
                        return bidiOn
                    }()
                    SubstitutionWordView(
                        word: word,
                        display: display,
                        isHighlighted: false,
                        verseKey: verse.verseKey
                    )
                    .layoutValue(key: WrappingHStack.IsArabic.self, value: isArabic)
                }
            }
            .lineSpacing(8)
        } else if let arabic = verse?.textUthmani {
            // Fallback for older cached entries that lack word-level data —
            // still useful (verse text is at least visible), and the next
            // background refresh will replace it.
            Text(arabic)
                .font(.system(size: 22))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.layoutDirection, .rightToLeft)
                .foregroundStyle(AyyatColors.textPrimary)
        }
    }

    @ViewBuilder
    private var translationLine: some View {
        if settings.verseExtraLine == .translation, let t = verse?.translations?.first?.text {
            Text(stripped(t))
                .font(.system(size: 13))
                .foregroundStyle(AyyatColors.textSecondary)
                .lineSpacing(2)
        }
    }

    // MARK: - Logic

    /// Synchronous load — runs before first paint, so no flash.
    private static func loadCached() -> Verse? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let v = try? JSONDecoder().decode(Verse.self, from: data)
        else { return Self.builtInFallback }
        return v
    }

    /// Fallback shipped in the binary — ensures the card never lives empty
    /// even on a fresh install with no internet.
    private static let builtInFallback: Verse = {
        Verse(
            id: 7813,
            verseKey: "55:13",
            verseNumber: 13,
            textUthmani: "فَبِأَىِّ ءَالَآءِ رَبِّكُمَا تُكَذِّبَانِ",
            textImlaei: nil,
            words: nil,
            translations: [Translation(id: 131, resourceId: 131,
                text: "So which of the favors of your Lord would you deny?")]
        )
    }()

    private func refreshIfNewDay() async {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let cachedDay = UserDefaults.standard.double(forKey: Self.cacheDateKey)
        // Cache is valid only when it's TODAY *and* the cached verse has
        // real word tokens we can run through substitution — not just
        // punctuation markers. A legacy cache with words:[{type:"end"}]
        // would otherwise skip refresh forever and leave the card unable
        // to render the substitution view (the headline differentiator).
        let hasRealWords = verse?.words?.contains(where: \.isWord) == true
        if cachedDay == today, hasRealWords {
            mirrorToWidget(verse)
            return
        }
        do {
            let v = try await quranStore.apiClient.fetchRandomVerse(
                translationId: settings.selectedTranslationId
            )
            self.verse = v
            cache(v)
            mirrorToWidget(v)
        } catch {
            // Stay on whatever we already had cached / the fallback.
        }
    }

    private func cache(_ v: Verse) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        UserDefaults.standard.set(today, forKey: Self.cacheDateKey)
    }

    private func mirrorToWidget(_ v: Verse?) {
        guard let v else { return }
        let english = (v.translations?.first?.text ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        AyyatSharedStorage.writeDailyAyah(
            verseKey: v.verseKey,
            arabic: v.textUthmani ?? "",
            english: english
        )
    }

    private func stripped(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

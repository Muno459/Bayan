import SwiftUI

/// Verse display modeled after quran.com:
/// - Toolbar with verse key + per-verse actions (play, bookmark, share, copy)
/// - Big Arabic text via progressive substitution (the ayyat differentiator)
/// - Translation underneath
/// - Tafsirs / Reflections footer that opens detail sheets
struct VerseCell: View {
    let verse: Verse
    let isCurrentVerse: Bool
    let currentWordIndex: Int?
    let onPlayVerse: () -> Void

    /// Memorize-mode hidden word ids (computed at the surah level by
    /// VerseReaderView). Empty when Memorize mode is off. Hidden words
    /// render as a blank box; tapping one calls `onPeekWord`.
    let hifzHiddenWordIds: Set<Int>
    let hifzTemporarilyRevealed: Set<Int>
    let onPeekWord: (Int) -> Void

    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(UserStore.self) private var userStore
    @Environment(OIDCAuthService.self) private var auth
    @Environment(\.colorScheme) private var colorScheme

    @State private var showStudy = false
    @State private var showMyNote = false
    @State private var copyConfirmed = false
    /// Cached note(s) for this verse, pulled from
    /// `GET /v1/notes/by-verse/{key}` on appear so the user can see
    /// (and tap → edit) what they previously wrote without having to
    /// open a separate Reflections list.
    @State private var verseNotes: [RemoteNote] = []
    @State private var editingNote: RemoteNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            substitutionView
            transliterationLine
            translationLine
            myNotePreview
            footerActions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(verseBackground)
        .overlay(alignment: .leading) {
            if isCurrentVerse {
                Rectangle().fill(AyyatColors.gold).frame(width: 3).padding(.vertical, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCurrentVerse)
        .animation(.easeInOut(duration: 0.15), value: currentWordIndex)
        .sheet(isPresented: $showStudy) {
            VerseStudySheet(verseKey: verse.verseKey)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMyNote) {
            // If a note already exists for this verse, open in edit mode
            // (pre-fills the body, PATCHes on save). Otherwise create a
            // fresh one. Same sheet, no separate "view note" UI.
            ReflectionSheet(
                verseKey: verse.verseKey,
                existingNote: verseNotes.first
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .onDisappear { Task { await refreshVerseNotes() } }
        }
        .task(id: auth.isSignedIn) {
            await refreshVerseNotes()
        }

        Divider().padding(.leading, 20)
    }

    /// Pull this verse's reflections from QF so the cell can show the
    /// existing note inline (or surface the "edit" affordance when the
    /// user taps the reflection button instead of forcing a new note).
    private func refreshVerseNotes() async {
        guard auth.isSignedIn else {
            verseNotes = []
            return
        }
        verseNotes = await userStore.reflectionsForVerse(verse.verseKey)
    }

    // MARK: - Toolbar (verse key + actions)

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(verse.verseKey)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AyyatColors.textSecondary)
                .monospacedDigit()

            Button { onPlayVerse() } label: {
                Image(systemName: isCurrentVerse ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrentVerse ? AyyatColors.primary : AyyatColors.textSecondary)
            }
            .accessibilityLabel("Play verse")

            Button {
                Haptics.medium()
                userStore.toggleBookmark(
                    verseKey: verse.verseKey,
                    chapterId: Int(verse.verseKey.split(separator: ":").first ?? "1") ?? 1,
                    verseNumber: verse.verseNumber
                )
            } label: {
                Image(systemName: userStore.isBookmarked(verse.verseKey) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13))
                    .foregroundStyle(
                        userStore.isBookmarked(verse.verseKey)
                            ? AyyatColors.gold : AyyatColors.textSecondary
                    )
            }
            .accessibilityLabel(userStore.isBookmarked(verse.verseKey) ? "Remove bookmark" : "Add bookmark")

            // Verse word progress chip — small ayyat-specific signal
            if verseProgress.total > 0 && verseProgress.known > 0 {
                let known = verseProgress.known, total = verseProgress.total
                Text("\(known)/\(total)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(AyyatColors.mastered.opacity(0.12)))
                    .foregroundStyle(known == total ? AyyatColors.mastered : AyyatColors.textSecondary)
                    .accessibilityLabel("\(known) of \(total) words known")
            }

            Spacer()

            Button {
                UIPasteboard.general.string = shareText
                Haptics.light()
                copyConfirmed = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copyConfirmed = false
                }
            } label: {
                Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(copyConfirmed ? AyyatColors.mastered : AyyatColors.textSecondary)
            }
            .accessibilityLabel("Copy verse")

            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            .accessibilityLabel("Share verse")
        }
    }

    // MARK: - Per-word substitution line

    /// The progressive-substitution surface: each Arabic word gets a
    /// slot, rendered in Arabic recitation order. `displayMode` decides
    /// per word whether the slot is English (Saheeh slice), transitioning
    /// (Arabic/transliteration on top with a hint beneath), or learned
    /// (bare Arabic or transliteration depending on the user's track).
    ///
    /// The natural-flow Saheeh sentence is rendered verbatim BELOW this
    /// line (see `translationLine`), so the user always has the canonical
    /// translation to read regardless of what's happening in these slots.
    private var substitutionView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        let saheeh = verse.translations?.first?.text
        let raw: [(Word, SubstitutionDisplay)] = words.enumerated().map { idx, word in
            (word, vocabularyStore.displayMode(
                for: word,
                saheeh: saheeh,
                isFirstWord: idx == 0
            ))
        }

        // Per-word breakdown is always active so word-by-word audio
        // highlighting + per-word tap-to-drill works at every slider
        // position. Direction handling now lives in `WrappingHStack`'s
        // bidi-aware mode: each row is laid out LTR, then consecutive
        // runs of Arabic words within that row are reversed in place.
        // This preserves animations, gestures, decorations, audio
        // highlight, and HifzBlankWord — and crucially fixes the
        // multi-line reading order (the previous global data-reorder
        // broke when an Arabic run spanned a wrap boundary).
        //
        // Transliteration mode disables the bidi pass because Latin
        // characters flow LTR.
        let bidiOn = settings.arabicMixedDirection == .rtl &&
                     !vocabularyStore.useTransliteration

        return AnyView(
            WrappingHStack(alignment: .leading, spacing: 4, bidiAware: bidiOn) {
                ForEach(raw, id: \.0.id) { word, display in
                    let isHighlighted = currentWordIndex != nil && word.position == currentWordIndex
                    let isHidden = hifzHiddenWordIds.contains(word.id) &&
                                   !hifzTemporarilyRevealed.contains(word.id)
                    let isArabic = bidiOn && isArabicDisplay(display)

                    if isHidden {
                        HifzBlankWord(word: word, fontSize: settings.arabicFontSize) {
                            Haptics.light()
                            onPeekWord(word.id)
                        }
                        .layoutValue(key: WrappingHStack.IsArabic.self, value: isArabic)
                    } else {
                        SubstitutionWordView(
                            word: word,
                            display: display,
                            isHighlighted: isHighlighted,
                            verseKey: verse.verseKey
                        )
                        .layoutValue(key: WrappingHStack.IsArabic.self, value: isArabic)
                    }
                }
            }
            .lineSpacing(10)
            .animation(.easeInOut(duration: 0.2), value: hifzHiddenWordIds)
            .animation(.easeInOut(duration: 0.18), value: hifzTemporarilyRevealed)
        )
    }

    /// True when the SubstitutionDisplay's primary script is Arabic
    /// (`learned` or `transitioning` both render Arabic glyphs). Used
    /// to tell `WrappingHStack`'s bidi-aware mode which children to
    /// treat as Arabic for per-row run reversal.
    private func isArabicDisplay(_ d: SubstitutionDisplay) -> Bool {
        if case .english = d { return false }
        return true
    }

    // MARK: - Optional transliteration line

    @ViewBuilder
    private var transliterationLine: some View {
        // One-of-three secondary-line system. `settings.verseExtraLine`
        // chooses between translation, transliteration, or none — the
        // two are mutually exclusive so we don't double-stack under the
        // Arabic. Render the transliteration only when the user picked
        // it AND they're not already in transliteration substitution
        // mode (where the substitution view itself is in Latin letters).
        if settings.verseExtraLine == .transliteration && !vocabularyStore.useTransliteration {
            let text = verse.words?
                .filter { $0.isWord }
                .compactMap { $0.transliteration?.text }
                .joined(separator: " ") ?? ""
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(AyyatColors.textSecondary.opacity(0.6))
                    .lineSpacing(3)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Translation

    /// Saheeh full-verse English, rendered verbatim — exactly as
    /// published, no reconstruction, no per-word slicing. Now the
    /// primary English surface of each verse since the line above is
    /// canonical Arabic only.
    ///
    /// Unconditional render: the per-word Arabic line above carries no
    /// English at all, so the user always needs the Saheeh sentence
    /// to read meaning. Old `verseExtraLine == .translation` gate
    /// removed — the setting now only controls the optional
    /// transliteration row, not whether the translation appears.
    @ViewBuilder
    private var translationLine: some View {
        if let translation = verse.translations?.first {
            Text(translation.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.system(size: settings.translationFontSize))
                .foregroundStyle(AyyatColors.textPrimary)
                .lineSpacing(5)
                .padding(.top, 6)
        }
    }

    // MARK: - My note preview
    //
    // If the user has already written a reflection on this verse, show it
    // inline as a small card. Tapping the card opens the editor in EDIT
    // mode so they update the existing note rather than creating a duplicate.

    @ViewBuilder
    private var myNotePreview: some View {
        if let first = verseNotes.first, let body = firstLine(of: first.body) {
            Button {
                showMyNote = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AyyatColors.primary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your reflection")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AyyatColors.primary)
                            .textCase(.uppercase)
                        Text(body)
                            .font(.system(size: 14))
                            .foregroundStyle(AyyatColors.textPrimary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AyyatColors.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(AyyatColors.primary.opacity(0.18), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Strip raw HTML the QF API sometimes returns inside a note body
    /// (the QuranReflect rich editor emits `<p>` wrappers etc.) and
    /// take the first non-empty line for the preview.
    private func firstLine(of body: String) -> String? {
        let stripped = body.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let line = stripped.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (line?.isEmpty == false) ? line : nil
    }

    // MARK: - Footer (Study | My note)

    private var footerActions: some View {
        HStack(spacing: 18) {
            footerButton(systemImage: "book.closed", label: "Study") {
                showStudy = true
            }
            footerDivider
            footerButton(systemImage: "text.bubble", label: "My note") {
                showMyNote = true
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func footerButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(AyyatColors.textSecondary)
        }
    }

    private var footerDivider: some View {
        Rectangle()
            .fill(AyyatColors.textSecondary.opacity(0.25))
            .frame(width: 1, height: 12)
    }

    // MARK: - Helpers

    private var verseBackground: Color {
        if isCurrentVerse {
            return AyyatColors.gold.opacity(0.06)
        }
        return colorScheme == .dark ? AyyatColors.readerBackgroundDark : AyyatColors.readerBackground
    }

    private var verseProgress: (known: Int, total: Int) {
        let words = verse.words?.filter { $0.isWord } ?? []
        let total = words.count
        let known = words.reduce(into: 0) { acc, word in
            if let state = vocabularyStore.wordStates[word.id], state.masteryLevel >= .familiar {
                acc += 1
            }
        }
        return (known, total)
    }

    private var shareText: String {
        let arabic = verse.textUthmani ?? ""
        let english = verse.translations?.first?.text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? ""
        return "\(arabic)\n\n\(english)\n\n[\(verse.verseKey)] · Quran"
    }
}

/// Renders a word in Memorize Mode as a tinted underline-only box that
/// preserves the underlying glyph's footprint (so line wrapping doesn't
/// shift when words are revealed/hidden). Tap to peek.
private struct HifzBlankWord: View {
    let word: Word
    let fontSize: CGFloat
    let onTap: () -> Void

    var body: some View {
        Text(word.textUthmani ?? "")
            .font(.system(size: fontSize))
            .environment(\.locale, Locale(identifier: "ar"))
            .foregroundStyle(.clear)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AyyatColors.primary.opacity(0.12))
            )
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(AyyatColors.primary.opacity(0.55))
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .padding(.bottom, -3)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

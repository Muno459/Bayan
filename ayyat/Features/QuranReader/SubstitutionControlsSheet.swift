import SwiftUI

struct SubstitutionControlsSheet: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(\.dismiss) private var dismiss
    @State private var showGraduationPrompt = false
    @State private var pendingHighLevel: Double?

    var body: some View {
        @Bindable var store = vocabularyStore

        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Learning Level")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(vocabularyStore.substitutionLevel * 100))%")
                                .font(.headline)
                                .foregroundStyle(AyyatColors.primary)
                        }

                        // We intercept slider writes via a custom Binding so
                        // a newbie can't accidentally drag straight to
                        // "all Arabic" without a one-time confirmation —
                        // otherwise the Quran would render as Arabic they
                        // can't yet read, which the user explicitly didn't
                        // want.
                        Slider(
                            value: Binding(
                                get: { store.substitutionLevel },
                                set: { newValue in
                                    let threshold = VocabularyStore.arabicGraduationThreshold
                                    if newValue >= threshold && !store.graduatedToArabic {
                                        // Park at the pre-graduation cap, ask
                                        // for confirmation. We remember the
                                        // target so we can honor it if the
                                        // user confirms.
                                        pendingHighLevel = newValue
                                        store.substitutionLevel = VocabularyStore.preGraduationCap
                                        showGraduationPrompt = true
                                    } else {
                                        store.substitutionLevel = newValue
                                    }
                                }
                            ),
                            in: 0...1, step: 0.05
                        )
                        .tint(AyyatColors.primary)

                        HStack {
                            Text("All English")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("All Arabic")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Substitution")
                } footer: {
                    Text(vocabularyStore.useTransliteration
                         ? "Controls how many English words are replaced with their pronunciation. Words you've learned through repeated reading are always shown."
                         : "Controls how many English words are replaced with their original Arabic script. Words you've learned through repeated reading are always shown in Arabic.")
                }

                // Preview
                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("In the name of")
                                .font(.system(size: 15))
                                .foregroundStyle(AyyatColors.textSecondary)

                            if vocabularyStore.useTransliteration {
                                Text("l-lahi")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AyyatColors.primary)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(AyyatColors.primary.opacity(0.07)))
                                Text("l-rahmani")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AyyatColors.primary)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(AyyatColors.primary.opacity(0.07)))
                            } else {
                                Text("ٱللَّهِ")
                                    .font(.system(size: 20))
                                    .foregroundStyle(AyyatColors.primary)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(AyyatColors.primary.opacity(0.07)))
                                Text("ٱلرَّحْمَـٰنِ")
                                    .font(.system(size: 20))
                                    .foregroundStyle(AyyatColors.primary)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(AyyatColors.primary.opacity(0.07)))
                            }

                            Text("the Merciful")
                                .font(.system(size: 15))
                                .foregroundStyle(AyyatColors.textSecondary)
                        }
                        Text(vocabularyStore.useTransliteration
                             ? "Green = words you've learned, shown as pronunciation"
                             : "Green = words you've learned, shown in Arabic script")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }

                Section("How It Works") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Read verses in English with Arabic words", systemImage: "1.circle.fill")
                        Label("Hear pronunciation by tapping Arabic words", systemImage: "2.circle.fill")
                        Label("More words become Arabic as you read", systemImage: "3.circle.fill")
                        Label("Eventually read the Quran in its original Arabic", systemImage: "4.circle.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(AyyatColors.textSecondary)
                }
            }
            .navigationTitle("Learning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("A note on respect", isPresented: $showGraduationPrompt) {
                Button("Not yet", role: .cancel) {
                    pendingHighLevel = nil
                }
                Button("I understand") {
                    store.graduatedToArabic = true
                    // Reset to a low substitution level so the user
                    // re-builds Arabic mastery word by word from a small
                    // base — sitting at near-full transliteration of the
                    // Quran isn't the intent. 10% keeps the verses
                    // predominantly in their original form; the user
                    // can drag back up as they progress.
                    store.substitutionLevel = VocabularyStore.postGraduationLevel
                    pendingHighLevel = nil
                }
            } message: {
                Text("Out of respect for the Quran, ayyat preserves the original Arabic — we won't transliterate the verses themselves; transliteration only applies to the tafsir / translation as a learning aid. When you tap \"I understand\", the slider resets to 10% so you grow your Arabic word by word from a small base. Drag it higher as words become familiar.")
            }
        }
    }
}

// StatRow removed — vocabulary progress is in the Progress tab

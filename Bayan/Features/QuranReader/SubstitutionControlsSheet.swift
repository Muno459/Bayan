import SwiftUI

struct SubstitutionControlsSheet: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = vocabularyStore

        NavigationStack {
            List {
                // Substitution Level
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Learning Level")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(vocabularyStore.substitutionLevel * 100))%")
                                .font(.headline)
                                .foregroundStyle(BayanColors.primary)
                        }

                        Slider(value: $store.substitutionLevel, in: 0...1, step: 0.1)
                            .tint(BayanColors.primary)

                        HStack {
                            Text("All English")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("All Transliteration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Substitution")
                } footer: {
                    Text("Controls how many English words are replaced with their phonetic Arabic (transliteration). Words you've learned through repeated reading are always shown in transliteration.")
                }

                // Preview
                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("In the name of")
                                .font(.system(size: 15))
                                .foregroundStyle(BayanColors.textSecondary)
                            Text("l-lahi")
                                .font(.system(size: 15, weight: .semibold, design: .serif))
                                .foregroundStyle(BayanColors.primary)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(BayanColors.primary.opacity(0.07)))
                            Text("l-rahmani")
                                .font(.system(size: 15, weight: .semibold, design: .serif))
                                .foregroundStyle(BayanColors.primary)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(BayanColors.primary.opacity(0.07)))
                            Text("the Merciful")
                                .font(.system(size: 15))
                                .foregroundStyle(BayanColors.textSecondary)
                        }
                        Text("Green = learned words shown as transliteration")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }

                // Stats
                Section("Vocabulary Progress") {
                    StatRow(label: "Words Encountered", value: "\(vocabularyStore.totalWordsEncountered)")
                    StatRow(label: "Mastered", value: "\(vocabularyStore.masteredCount)", color: BayanColors.mastered)
                    StatRow(label: "Familiar", value: "\(vocabularyStore.familiarCount)", color: BayanColors.introduced)
                    StatRow(label: "Learning", value: "\(vocabularyStore.learningCount)", color: BayanColors.learning)
                }

                // How it works
                Section("How It Works") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Read verses — Bayan tracks every word", systemImage: "1.circle.fill")
                        Label("Hear audio — words get reinforced", systemImage: "2.circle.fill")
                        Label("English words become transliteration", systemImage: "3.circle.fill")
                        Label("You naturally learn Quranic Arabic sounds", systemImage: "4.circle.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(BayanColors.textSecondary)
                }
            }
            .navigationTitle("Learning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }
}

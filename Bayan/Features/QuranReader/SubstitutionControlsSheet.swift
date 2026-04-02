import SwiftUI

/// Controls for adjusting the progressive substitution level
struct SubstitutionControlsSheet: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = vocabularyStore

        NavigationStack {
            List {
                // Substitution Level Slider
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Substitution Level")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(vocabularyStore.substitutionLevel * 100))%")
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }

                        Slider(value: $store.substitutionLevel, in: 0...1, step: 0.1)

                        HStack {
                            Text("All English")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("All Arabic")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Reading Level")
                } footer: {
                    Text("Controls how many English words are replaced with Arabic. Words you've learned are always shown in Arabic regardless of this setting.")
                }

                // Vocabulary Stats
                Section("Vocabulary Progress") {
                    StatRow(label: "Words Encountered", value: "\(vocabularyStore.totalWordsEncountered)")
                    StatRow(label: "Mastered", value: "\(vocabularyStore.masteredCount)", color: .green)
                    StatRow(label: "Familiar", value: "\(vocabularyStore.familiarCount)", color: .blue)
                    StatRow(label: "Learning", value: "\(vocabularyStore.learningCount)", color: .orange)
                }

                // Legend
                Section("How It Works") {
                    LegendRow(
                        color: .primary,
                        label: "English",
                        description: "Words you haven't learned yet"
                    )
                    LegendRow(
                        color: .accentColor,
                        label: "Arabic",
                        description: "Words you've mastered — shown in Arabic"
                    )
                    LegendRow(
                        color: .secondary,
                        label: "Transitioning",
                        description: "Words you're learning — Arabic with English hint"
                    )
                }
            }
            .navigationTitle("Substitution")
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

private struct LegendRow: View {
    let color: Color
    let label: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

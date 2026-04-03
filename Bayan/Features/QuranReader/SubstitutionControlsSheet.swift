import SwiftUI

struct SubstitutionControlsSheet: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(\.dismiss) private var dismiss

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
                                .foregroundStyle(BayanColors.primary)
                        }

                        Slider(value: $store.substitutionLevel, in: 0...1, step: 0.1)
                            .tint(BayanColors.primary)

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
                    Text("Controls how many English words are replaced with their original Arabic script. Words you've learned through repeated reading are always shown in Arabic.")
                }

                // Preview
                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("In the name of")
                                .font(.system(size: 15))
                                .foregroundStyle(BayanColors.textSecondary)
                            Text("ٱللَّهِ")
                                .font(.system(size: 20, design: .serif))
                                .foregroundStyle(BayanColors.primary)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(BayanColors.primary.opacity(0.07)))
                            Text("ٱلرَّحْمَـٰنِ")
                                .font(.system(size: 20, design: .serif))
                                .foregroundStyle(BayanColors.primary)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(BayanColors.primary.opacity(0.07)))
                            Text("the Merciful")
                                .font(.system(size: 15))
                                .foregroundStyle(BayanColors.textSecondary)
                        }
                        Text("Green = words you've learned, shown in Arabic script")
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

// StatRow removed — vocabulary progress is in the Progress tab

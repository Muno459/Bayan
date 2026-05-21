import SwiftUI

/// Search across the Quran via the /search/v1/search endpoint.
/// Debounced text field → list of result rows; tapping a result navigates
/// to the verse in its chapter.
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuranStore.self) private var quranStore

    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    let onSelect: (Int, String) -> Void  // (chapterId, verseKey)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                resultsBody
            }
            .navigationTitle("Search the Quran")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AyyatColors.textSecondary)
            TextField("Search verses, words, themes", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { _, new in
                    debouncedSearch(for: new)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.6))
                }
            }
        }
        .padding(12)
        .background(AyyatColors.readerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var resultsBody: some View {
        if isLoading && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            // The Quran Foundation pre-live key doesn't include search scope
            // by default — the API returns `insufficient_scope`. Surface a
            // calm, accurate explanation rather than a scary error.
            if error.lowercased().contains("insufficient_scope") || error.contains("403") {
                searchUnavailableState
            } else {
                ContentUnavailableView(
                    "Couldn't search",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            }
        } else if query.isEmpty {
            emptyState
        } else if results.isEmpty && !isLoading {
            ContentUnavailableView.search
        } else {
            List(results) { result in
                Button {
                    if let chapterId = chapterId(from: result.verseKey) {
                        onSelect(chapterId, result.verseKey)
                        dismiss()
                    }
                } label: {
                    resultRow(result)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var searchUnavailableState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(AyyatColors.gold)
            Text("Search is coming soon")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Full-text Quran search ships in the next update.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(AyyatColors.textSecondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(AyyatColors.primary.opacity(0.7))
            Text("Find a verse")
                .font(.system(size: 18, weight: .semibold))
            Text("Try \"mercy\", \"patience\", \"ayatul kursi\"")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verseLabel(for: result.verseKey))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AyyatColors.primary)
                Spacer()
                Text(result.verseKey)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .monospacedDigit()
            }
            if let arabic = result.text, !arabic.isEmpty {
                Text(arabic)
                    .font(.system(size: 18))
                    .lineLimit(2)
                    .foregroundStyle(AyyatColors.textPrimary)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            if let snippet = result.highlighted ?? result.translations?.first?.text {
                Text(stripHTML(snippet))
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .foregroundStyle(AyyatColors.textSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func debouncedSearch(for q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isLoading = false
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ q: String) async {
        isLoading = true
        error = nil
        do {
            results = try await quranStore.apiClient.search(query: q)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.results = []
        }
        isLoading = false
    }

    private func chapterId(from verseKey: String) -> Int? {
        Int(verseKey.split(separator: ":").first ?? "")
    }

    private func verseLabel(for verseKey: String) -> String {
        guard let cid = chapterId(from: verseKey) else { return "Verse" }
        return quranStore.chapters.first(where: { $0.id == cid })?.nameSimple ?? "Surah \(cid)"
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

import SwiftUI

/// Themes, revelation context, and summary for a surah.
/// Pulls /chapters/{id}/info from the Content API.
struct ChapterInfoSheet: View {
    let chapter: Chapter

    @Environment(\.dismiss) private var dismiss
    @Environment(QuranStore.self) private var quranStore

    @State private var info: ChapterInfo?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if let error {
                        ContentUnavailableView(
                            "Couldn't load",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                    } else if let info {
                        infoBody(info)
                    }
                }
                .padding(20)
            }
            .navigationTitle("About \(chapter.nameSimple)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(chapter.nameArabic)
                .font(.system(size: 30))
                .foregroundStyle(AyyatColors.primary)
            Text(chapter.nameSimple)
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 6) {
                if let place = chapter.revelationPlace {
                    Text(place.capitalized)
                }
                Text("·")
                Text("\(chapter.versesCount) ayahs")
                Text("·")
                Text("#\(chapter.id)")
            }
            .font(.system(size: 12))
            .foregroundStyle(AyyatColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func infoBody(_ info: ChapterInfo) -> some View {
        if let short = info.shortText, !short.isEmpty {
            Text(short)
                .font(.system(size: 14))
                .italic()
                .foregroundStyle(AyyatColors.textSecondary)
        }
        if let text = info.text, !text.isEmpty {
            FormattedHTMLView(html: text)
        } else if (info.text?.isEmpty ?? true) && (info.shortText?.isEmpty ?? true) {
            // Only show the "no context" message when BOTH primary text
            // and short-text are empty. Previously a null short_text alone
            // triggered this even when the body had real content.
            Text("No additional context available for this surah.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        if let source = info.source, !source.isEmpty {
            Divider().padding(.vertical, 6)
            Text("Source: \(source)")
                .font(.system(size: 11))
                .foregroundStyle(AyyatColors.textSecondary)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            info = try await quranStore.apiClient.fetchChapterInfo(chapterNumber: chapter.id)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

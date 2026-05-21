import SwiftUI

/// Three-tab study panel for an ayah, modeled after quran.com:
/// Tafsirs · Lessons · Reflections. Replaces the standalone TafsirSheet.
struct VerseStudySheet: View {
    let verseKey: String

    enum Tab: String, CaseIterable, Identifiable {
        case tafsir, lessons, reflections
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tafsir: "Tafsir"
            case .lessons: "Lessons"
            case .reflections: "Reflections"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Tab = .tafsir

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selected) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                switch selected {
                case .tafsir:      TafsirPane(verseKey: verseKey)
                case .lessons:     PostsPane(verseKey: verseKey, kind: .lesson)
                case .reflections: PostsPane(verseKey: verseKey, kind: .reflection)
                }
            }
            // Short title — "Study · 2:255" truncated to "Study · 2" on
            // compact widths because iOS breaks at the colon. Just use the
            // verse key so the full ayah reference is always visible.
            .navigationTitle(verseKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Tafsir pane (extracted from TafsirSheet so it lives next to siblings)

struct TafsirPane: View {
    let verseKey: String

    @Environment(QuranStore.self) private var quranStore

    @State private var tafsir: TafsirText?
    @State private var error: String?
    @State private var isLoading = true
    @State private var availableTafsirs: [TafsirResource] = []
    @State private var selectedTafsirId: Int = 169  // Ibn Kathir abridged

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error {
                    ContentUnavailableView(
                        "Couldn't load tafsir",
                        systemImage: "wifi.exclamationmark",
                        description: Text(error)
                    )
                } else if let tafsir {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(tafsir.resourceName ?? "Tafsir")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AyyatColors.textSecondary)
                            .textCase(.uppercase)
                            .tracking(0.8)
                        FormattedHTMLView(html: tafsir.text)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .task(id: selectedTafsirId) { await load() }
    }

    @ViewBuilder
    private var header: some View {
        if availableTafsirs.count > 1 {
            Menu {
                ForEach(availableTafsirs) { t in
                    Button {
                        selectedTafsirId = t.id
                    } label: {
                        HStack {
                            Text(t.name)
                            if t.id == selectedTafsirId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(AyyatColors.primary)
            }
        }
    }

    private var currentLabel: String {
        availableTafsirs.first(where: { $0.id == selectedTafsirId })?.name ?? "Tafsir"
    }

    private func load() async {
        isLoading = true
        error = nil
        let client = quranStore.apiClient
        do {
            if availableTafsirs.isEmpty {
                async let list = client.fetchTafsirs()
                async let text = client.fetchTafsir(tafsirId: selectedTafsirId, verseKey: verseKey)
                availableTafsirs = (try await list).filter { $0.languageName?.lowercased() == "english" }
                tafsir = try await text
            } else {
                tafsir = try await client.fetchTafsir(tafsirId: selectedTafsirId, verseKey: verseKey)
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Posts pane (Lessons + Reflections share UI, differ by type filter)

struct PostsPane: View {
    let verseKey: String
    let kind: Kind

    enum Kind: Hashable {
        case lesson, reflection

        var apiType: String {
            switch self {
            case .lesson:     "lesson"
            case .reflection: "reflection"
            }
        }
        var emptyTitle: String {
            switch self {
            case .lesson:     "No lessons for this ayah yet"
            case .reflection: "No reflections shared yet"
            }
        }
        var emptyHint: String {
            switch self {
            case .lesson:     "Editorial lessons from Quran Reflect appear here as they're published."
            case .reflection: "Community reflections from Quran Reflect appear here."
            }
        }
        var icon: String {
            switch self {
            case .lesson:     "graduationcap"
            case .reflection: "text.bubble"
            }
        }
    }

    @Environment(QuranStore.self) private var quranStore

    @State private var posts: [ReflectPost] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && posts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Couldn't load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            } else if posts.isEmpty {
                ContentUnavailableView(
                    kind.emptyTitle,
                    systemImage: kind.icon,
                    description: Text(kind.emptyHint)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(posts) { post in
                            PostCard(post: post)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        // Re-load when the segmented control swaps tabs (kind change) or
        // when the verse changes. SwiftUI owns cancellation here — when
        // either part of the id changes, the previous .task body is
        // cancelled and `load()` returns at the next `try await` point.
        // The earlier nested-Task wrapper bypassed that cancellation.
        .task(id: "\(verseKey)|\(kind.apiType)") {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await quranStore.apiClient.fetchPosts(verseKey: verseKey, type: kind.apiType)
            try Task.checkCancellation()
            posts = result
        } catch is CancellationError {
            return
        } catch {
            // Suppress error message if our task was cancelled mid-fetch
            // (user switched tabs) — only surface real failures.
            guard !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct PostCard: View {
    let post: ReflectPost
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = post.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
            }
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.primary.opacity(0.6))
                Text(post.author?.displayName ?? "Anonymous")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AyyatColors.textSecondary)
                Spacer()
                if let likes = post.likes, likes > 0 {
                    Label("\(likes)", systemImage: "heart")
                        .font(.system(size: 11))
                        .foregroundStyle(AyyatColors.textSecondary)
                }
            }
            if let body = post.body, !body.isEmpty {
                if expanded {
                    FormattedHTMLView(html: body)
                } else {
                    Text(plainPreview(body))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .lineLimit(4)
                        .foregroundStyle(AyyatColors.textPrimary)
                    Button(expanded ? "Show less" : "Read more") {
                        withAnimation { expanded = true }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AyyatColors.primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AyyatColors.cardBackground)
        )
    }

    private func plainPreview(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

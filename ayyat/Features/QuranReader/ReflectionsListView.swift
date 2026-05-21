import SwiftUI

/// Lists the signed-in user's saved reflections (Notes API).
/// Pulls /auth/v1/notes and shows the body + verse key.
struct ReflectionsListView: View {
    @Environment(QuranStore.self) private var quranStore
    @Environment(UserStore.self) private var userStore
    @Environment(OIDCAuthService.self) private var auth

    @State private var notes: [RemoteNote] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var editingNote: RemoteNote?

    var body: some View {
        Group {
            if !auth.isSignedIn {
                signInPrompt
            } else if isLoading && notes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Couldn't load reflections",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            } else if notes.isEmpty {
                ContentUnavailableView(
                    "No reflections yet",
                    systemImage: "text.bubble",
                    description: Text("Tap \"Reflection\" under any verse to save your thoughts.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(notes) { note in
                            noteCard(note)
                                .contextMenu {
                                    Button {
                                        editingNote = note
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        Task { await delete(note) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await delete(note) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        editingNote = note
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(AyyatColors.primary)
                                }
                                .onTapGesture {
                                    editingNote = note
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Reflections")
        .navigationBarTitleDisplayMode(.large)
        .background(AyyatColors.background)
        .task { await load() }
        .sheet(item: $editingNote) { note in
            ReflectionSheet(
                verseKey: note.verseKey ?? "",
                existingNote: note
            )
            .onDisappear { Task { await load() } }
        }
    }

    private func delete(_ note: RemoteNote) async {
        // Optimistic — remove locally, hit DELETE, reload on failure.
        notes.removeAll { $0.id == note.id }
        let ok = await userStore.deleteReflection(id: note.id)
        if !ok {
            await load()
        } else {
            Haptics.medium()
        }
    }

    private func noteCard(_ note: RemoteNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: verse chip + chapter name + relative date
            HStack(spacing: 8) {
                if let key = note.verseKey, let chapter = chapterName(for: key) {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(chapter) · \(key)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [AyyatColors.primary.opacity(0.18),
                                         AyyatColors.gold.opacity(0.18)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                    .foregroundStyle(AyyatColors.primary)
                }
                Spacer()
                if let date = note.updatedAt ?? note.createdAt {
                    Text(prettyDate(date))
                        .font(.system(size: 11))
                        .foregroundStyle(AyyatColors.textSecondary)
                }
            }

            // Body
            Text(stripHTML(note.body))
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(AyyatColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AyyatColors.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
    }

    private func chapterName(for verseKey: String) -> String? {
        let parts = verseKey.split(separator: ":").map(String.init)
        guard let chapterIdStr = parts.first, let chapterId = Int(chapterIdStr) else { return nil }
        return quranStore.chapters.first(where: { $0.id == chapterId })?.nameSimple
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(AyyatColors.primary)
            Text("Sign in to see your reflections")
                .font(.system(size: 17, weight: .semibold))
            Text("Reflections sync to your Quran.com account.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { try? await auth.signIn() }
            } label: {
                Text("Sign in with Quran.com")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AyyatColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard auth.isSignedIn, let api = userStore.userAPI else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await api.listNotes()
                .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func prettyDate(_ iso: String) -> String {
        // QF's Notes API timestamps include fractional seconds, which
        // ISO8601DateFormatter rejects by default. Enable that option
        // and fall back to non-fractional if needed.
        let isoF = ISO8601DateFormatter()
        isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = isoF.date(from: iso) ?? {
            isoF.formatOptions = [.withInternetDateTime]
            return isoF.date(from: iso)
        }()
        guard let d = parsed else { return iso }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

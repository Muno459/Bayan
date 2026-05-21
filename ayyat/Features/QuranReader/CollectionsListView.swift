import SwiftUI

/// Lists the user's QuranReflect bookmark Collections via QF's
/// `GET /v1/collections`. Lets them create a new collection (POST
/// /v1/collections) and delete existing ones (DELETE /v1/collections/{id}).
///
/// Adding bookmarks to a collection happens contextually from the verse
/// reader / bookmark menu — this view is the "organize and browse"
/// surface.
struct CollectionsListView: View {
    @Environment(UserStore.self) private var userStore
    @Environment(OIDCAuthService.self) private var auth

    @State private var collections: [RemoteCollection] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var newName: String = ""
    @State private var showNewSheet = false

    var body: some View {
        Group {
            if !auth.isSignedIn {
                signInPrompt
            } else if isLoading && collections.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Couldn't load collections",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            } else if collections.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(collections) { collection in
                            collectionRow(collection)
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        Text("\(collections.count) collection\(collections.count == 1 ? "" : "s"). Synced via Quran.com.")
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if auth.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            newCollectionSheet
        }
        .task { await load() }
    }

    private func collectionRow(_ collection: RemoteCollection) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AyyatColors.primary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: collection.isDefault == true ? "folder.fill" : "tray.full.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AyyatColors.textPrimary)
                let count = collection.bookmarksCount ?? collection.resourcesCount ?? 0
                Text("\(count) bookmark\(count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AyyatColors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No collections yet", systemImage: "tray")
        } description: {
            Text("Create a collection to group bookmarks by theme — e.g. \"Mercy\", \"Prayer\", \"Patience\".")
        } actions: {
            Button {
                showNewSheet = true
            } label: {
                Text("Create your first collection")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AyyatColors.primary))
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(AyyatColors.primary)
            Text("Sign in to manage collections")
                .font(.system(size: 17, weight: .semibold))
            Text("Collections sync across devices via your Quran.com account.")
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

    private var newCollectionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Collection name", text: $newName)
                        .autocorrectionDisabled(false)
                } footer: {
                    Text("e.g. \"Mercy verses\", \"Daily wird\", \"Tafsir studies\".")
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        newName = ""
                        showNewSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        Task { await createNew() }
                    }
                    .bold()
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func load() async {
        guard auth.isSignedIn, let api = userStore.userAPI else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            collections = try await api.listCollections()
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func createNew() async {
        guard let api = userStore.userAPI else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if let new = try await api.createCollection(name: trimmed) {
                collections.insert(new, at: 0)
                Haptics.success()
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        newName = ""
        showNewSheet = false
    }

    private func delete(at offsets: IndexSet) {
        guard let api = userStore.userAPI else { return }
        let toRemove = offsets.map { collections[$0] }
        for c in toRemove {
            // Don't let users delete the default collection — the API
            // either rejects this or silently removes nothing.
            if c.isDefault == true { continue }
            Task { _ = try? await api.deleteCollection(id: c.id) }
        }
        collections.remove(atOffsets: offsets)
    }
}

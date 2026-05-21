import SwiftUI

/// Personal reflection on a verse.
/// On submit, POSTs to /auth/v1/notes — the Quran Foundation Notes (Reflections) endpoint.
/// If the user is not signed in, prompts for sign-in first.
struct ReflectionSheet: View {
    let verseKey: String
    /// When non-nil, the sheet is in EDIT mode — pre-fills the body
    /// and PATCHes the existing note on save instead of creating one.
    let existingNote: RemoteNote?

    init(verseKey: String, existingNote: RemoteNote? = nil) {
        self.verseKey = verseKey
        self.existingNote = existingNote
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(OIDCAuthService.self) private var auth
    @Environment(UserStore.self) private var userStore
    @FocusState private var isFocused: Bool

    @State private var text: String = ""
    @State private var isSaving = false
    @State private var saved = false
    @State private var publishToCommunity = false
    @State private var publishedPostId: Int?
    @State private var error: String?

    /// QF Notes API requires `body.length >= 6`. Below that the server
    /// rejects with 422 "must be at least 6 characters long". Gate the
    /// Save button so the user can't trigger an avoidable error.
    private var meetsMinLength: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if !auth.isSignedIn {
                    signInPrompt
                } else if saved {
                    successView
                } else {
                    editor
                }
            }
            .padding(20)
            .navigationTitle(existingNote == nil
                              ? "Reflection · \(verseKey)"
                              : "Edit · \(verseKey)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if text.isEmpty, let body = existingNote?.body {
                    text = body
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { closeSheet() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if auth.isSignedIn && !saved {
                        Button("Save") { Task { await save() } }
                            .disabled(!meetsMinLength || isSaving)
                            .bold()
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What did this ayah reveal to you?")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)

            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: 16))
                .lineSpacing(4)
                .padding(8)
                .background(AyyatColors.readerBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AyyatColors.textSecondary.opacity(0.15), lineWidth: 1)
                )
                .frame(minHeight: 180)
                .onAppear { isFocused = true }

            HStack(spacing: 6) {
                Image(systemName: meetsMinLength ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(meetsMinLength ? AyyatColors.mastered : AyyatColors.textSecondary)
                Text(meetsMinLength
                     ? "Looks good"
                     : "At least 6 characters")
                    .font(.system(size: 12))
                    .foregroundStyle(AyyatColors.textSecondary)
                Spacer()
                let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
                Text("\(count) / 10000")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AyyatColors.textSecondary.opacity(0.6))
            }

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }

            // Optional: also publish as a public post on QuranReflect.
            // Wired to QF's `POST /v1/notes/{id}/publish`. When off, the
            // note stays private to the user's Quran.com account.
            Toggle(isOn: $publishToCommunity) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AyyatColors.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share on QuranReflect")
                            .font(.system(size: 14, weight: .medium))
                        Text("Publish publicly to the community feed")
                            .font(.system(size: 11))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }
            }
            .tint(AyyatColors.primary)
            .padding(.vertical, 4)

            Text(publishToCommunity
                ? "Visible to the QuranReflect community."
                : "Synced to your Quran.com account. Visible only to you.")
                .font(.system(size: 12))
                .foregroundStyle(AyyatColors.textSecondary.opacity(0.7))

            Spacer()
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(AyyatColors.primary)
            Text("Sign in to save reflections")
                .font(.system(size: 17, weight: .semibold))
            Text("Your reflections sync across your devices via your Quran.com account.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    try? await auth.signIn()
                }
            } label: {
                Text("Sign in with Quran.com")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AyyatColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(AyyatColors.mastered)
            Text(publishedPostId != nil ? "Reflection shared" : "Reflection saved")
                .font(.system(size: 17, weight: .semibold))
            Text(publishedPostId != nil
                 ? "Published to the QuranReflect community."
                 : "Stored privately in your Quran.com account.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
            if publishToCommunity && publishedPostId == nil {
                Text("Could not publish to community — saved privately only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private func save() async {
        isSaving = true
        error = nil

        // Edit mode: PATCH the existing note instead of creating one.
        if let existing = existingNote {
            let ok = await userStore.updateReflection(id: existing.id, body: text)
            isSaving = false
            if ok {
                saved = true
                Haptics.success()
                try? await Task.sleep(for: .seconds(1.2))
                closeSheet()
            } else {
                error = "Could not update reflection. Try again."
            }
            return
        }

        let noteId = await userStore.saveReflection(verseKey: verseKey, body: text)
        if let noteId {
            // If the user opted in, also publish to the QuranReflect
            // community feed as a public post. This is a second API call
            // (`POST /v1/notes/{id}/publish`) — we surface its outcome
            // in the success view.
            if publishToCommunity {
                publishedPostId = await userStore.publishReflection(
                    noteId: noteId,
                    body: text,
                    verseKey: verseKey
                )
            }
            saved = true
            Haptics.success()
            isSaving = false
            try? await Task.sleep(for: .seconds(1.4))
            closeSheet()
        } else {
            isSaving = false
            error = "Could not save reflection. Check your connection and try again."
        }
    }

    /// Resign keyboard focus FIRST, then dismiss on the next runloop tick.
    /// iOS's keyboard hide is an IPC handshake with the keyboard process;
    /// dismissing the sheet while the keyboard is still mid-hide causes a
    /// 3-second `Result accumulator timeout` freeze. Letting the focus
    /// resignation complete before tearing down the view avoids it.
    private func closeSheet() {
        isFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            dismiss()
        }
    }
}

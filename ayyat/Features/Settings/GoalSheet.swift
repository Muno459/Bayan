import SwiftUI

/// Set a daily reading goal (verses per day). POSTs to /auth/v1/goals.
/// Cached locally for offline display.
struct GoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OIDCAuthService.self) private var auth
    @Environment(UserStore.self) private var userStore
    @AppStorage("ayyat.dailyVerseGoal") private var localGoal: Int = 10

    @State private var target: Int = 10
    @State private var isSaving = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if !auth.isSignedIn {
                    signInPrompt
                } else if saved {
                    successView
                } else {
                    editor
                }
            }
            .padding(20)
            .navigationTitle("Daily Reading Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if auth.isSignedIn && !saved {
                        Button("Save") { Task { await save() } }
                            .disabled(isSaving)
                            .bold()
                    }
                }
            }
        }
        .onAppear { target = max(1, localGoal) }
    }

    private var editor: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("\(target)")
                    .font(.system(size: 78, weight: .bold, design: .rounded))
                    .foregroundStyle(AyyatColors.primary)
                    .monospacedDigit()
                Text(target == 1 ? "verse per day" : "verses per day")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.textSecondary)
            }
            .padding(.top, 20)

            // Stepper row — no slider track to be mistaken for a divider.
            HStack(spacing: 24) {
                stepperButton(systemImage: "minus") {
                    if target > 1 { target -= 1; Haptics.light() }
                }
                stepperButton(systemImage: "plus") {
                    if target < 100 { target += 1; Haptics.light() }
                }
            }

            // Quick presets — covers the common goal values without
            // needing to mash the stepper 50 times.
            HStack(spacing: 8) {
                ForEach([5, 10, 20, 50, 100], id: \.self) { preset in
                    Button {
                        Haptics.selection()
                        target = preset
                    } label: {
                        Text("\(preset)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(target == preset
                                          ? AyyatColors.primary
                                          : AyyatColors.primary.opacity(0.08))
                            )
                            .foregroundStyle(target == preset ? .white : AyyatColors.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            Text("Recommended: ~10 verses/day completes the Quran in just over a year.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(AyyatColors.textSecondary)
                .padding(.horizontal, 12)

            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red)
            }

            Spacer()
        }
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AyyatColors.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AyyatColors.primary.opacity(0.1)))
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(AyyatColors.primary)
            Text("Sign in to sync your goal")
                .font(.system(size: 16, weight: .semibold))
            Text("Your daily reading goal will sync across your devices.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(AyyatColors.textSecondary)
            Button {
                Task { try? await auth.signIn() }
            } label: {
                Text("Sign in with Quran.com")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 10).padding(.horizontal, 20)
                    .background(AyyatColors.primary)
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 30)
    }

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(AyyatColors.mastered)
            Text("Goal saved")
                .font(.system(size: 17, weight: .semibold))
            Text("\(target) verse\(target == 1 ? "" : "s") per day")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
        }
        .padding(.top, 40)
    }

    private func save() async {
        guard let api = userStore.userAPI else { error = "Not signed in"; return }
        isSaving = true
        defer { isSaving = false }  // resets BEFORE dismiss so the disabled
                                    // state doesn't linger on the success path.
        error = nil
        do {
            _ = try await api.createDailyVersesGoal(target: target)
            localGoal = target
            saved = true
            Haptics.success()
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

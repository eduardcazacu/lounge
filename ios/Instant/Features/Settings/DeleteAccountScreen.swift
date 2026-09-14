#if canImport(UIKit)
import SwiftUI

/// Guideline 5.1.1(v): an account made in the app can be deleted in the app.
struct DeleteAccountScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: DeleteAccountModel?
    @State private var confirming = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                InstantStyle.background.ignoresSafeArea()

                if let model {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("This can't be undone", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundStyle(InstantStyle.unread)
                                Text("Your Eddie's Lounge account is deleted straight away, on the app and on the web: your profile, conversations, streaks, instants, posts, comments and chat messages. Anything waiting for you will be lost.")
                                    .font(.subheadline)
                                    .foregroundStyle(InstantStyle.primaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(InstantStyle.surface)

                        Section {
                            SecureField(
                                "",
                                text: Binding(get: { model.password }, set: { model.password = $0 }),
                                prompt: Text("Password").foregroundStyle(InstantStyle.secondaryText)
                            )
                            .textContentType(.password)
                            .foregroundStyle(InstantStyle.primaryText)
                            .focused($passwordFocused)
                            .submitLabel(.done)
                            .accessibilityIdentifier("deleteAccount.password")
                        } header: {
                            Text("Enter your password to confirm")
                        } footer: {
                            if let error = model.errorMessage {
                                Text(error)
                                    .foregroundStyle(InstantStyle.unread)
                                    .accessibilityIdentifier("deleteAccount.error")
                            }
                        }
                        .listRowBackground(InstantStyle.surface)

                        Section {
                            Button(role: .destructive) {
                                passwordFocused = false
                                confirming = true
                            } label: {
                                HStack {
                                    Spacer()
                                    if model.isDeleting {
                                        ProgressView().tint(InstantStyle.unread)
                                    } else {
                                        Text("Delete my account").fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(!model.canDelete)
                            .accessibilityIdentifier("deleteAccount.submit")
                        }
                        .listRowBackground(InstantStyle.surface)
                    }
                    .scrollContentBackground(.hidden)
                    .confirmationDialog(
                        "Delete your account for good?",
                        isPresented: $confirming,
                        titleVisibility: .visible
                    ) {
                        Button("Delete account", role: .destructive) {
                            Task {
                                guard await model.delete() else { return }
                                dismiss()
                                await environment.didDeleteAccount()
                            }
                        }
                        .accessibilityIdentifier("deleteAccount.confirm")
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(.white)
                        .accessibilityIdentifier("deleteAccount.cancel")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model?.isDeleting ?? false)
        .onAppear {
            if model == nil { model = DeleteAccountModel(userAPI: environment.userAPI) }
            passwordFocused = true
        }
    }
}
#endif

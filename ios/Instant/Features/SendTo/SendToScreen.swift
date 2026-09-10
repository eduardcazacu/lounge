#if canImport(UIKit)
import SwiftUI

struct SendToScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ComposeModel
    let onSent: () -> Void

    @State private var recipients: SendToModel?

    var body: some View {
        NavigationStack {
            ZStack {
                InstantStyle.background.ignoresSafeArea()

                if let recipients {
                    List {
                        ForEach(recipients.candidates) { candidate in
                            row(candidate, in: recipients)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if recipients.isLoading && recipients.candidates.isEmpty {
                            ProgressView().tint(.white)
                        }
                    }
                }
            }
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if model.isSending {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send").fontWeight(.bold)
                        }
                    }
                    .tint(.white)
                    .disabled(recipients?.selectedId == nil || model.isSending)
                    .accessibilityIdentifier("sendTo.send")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if recipients == nil {
                recipients = SendToModel(
                    userAPI: environment.userAPI,
                    instantAPI: environment.instantAPI,
                    recentContacts: environment.recentContacts,
                    currentUserId: environment.session.currentUserId
                )
            }
            await recipients?.load()
        }
    }

    private func row(_ candidate: SendToModel.Candidate, in recipients: SendToModel) -> some View {
        let enrolled = candidate.isEnrolled
        let selectable = enrolled != false

        return Button {
            recipients.selectedId = candidate.id
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    name: candidate.user.displayName,
                    themeKey: candidate.user.themeKey,
                    url: candidate.user.profilePictureUrl,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.user.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(InstantStyle.primaryText)
                    if enrolled == false {
                        Text("Hasn't set up Instant yet")
                            .font(.caption)
                            .foregroundStyle(InstantStyle.secondaryText)
                    } else if enrolled == nil {
                        Text("Checking…")
                            .font(.caption)
                            .foregroundStyle(InstantStyle.secondaryText)
                    }
                }

                Spacer()

                if let streak = environment.store.streak(withUserId: candidate.id) {
                    StreakBadge(streak: streak)
                }

                Image(
                    systemName: recipients.selectedId == candidate.id
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .foregroundStyle(
                    recipients.selectedId == candidate.id ? Color.white : InstantStyle.secondaryText
                )
            }
            .contentShape(Rectangle())
            .opacity(selectable ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .listRowBackground(InstantStyle.background)
        .listRowSeparatorTint(InstantStyle.surfaceRaised)
        .accessibilityIdentifier("sendTo.row.\(candidate.user.displayName)")
    }

    private func send() async {
        guard let recipientId = recipients?.selectedId else { return }
        await model.send(to: recipientId)
        if case .sent = model.sendState {
            environment.recordSend(to: recipientId)
            await environment.store.refreshStreaks()
            dismiss()
            onSent()
        }
    }
}
#endif

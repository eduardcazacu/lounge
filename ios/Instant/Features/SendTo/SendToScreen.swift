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
                        if recipients.showsSections {
                            Section {
                                ForEach(recipients.recent) { candidate in
                                    row(candidate, in: recipients)
                                }
                            } header: {
                                sectionHeader("Recent")
                            }

                            if !recipients.everyoneElse.isEmpty {
                                Section {
                                    ForEach(recipients.everyoneElse) { candidate in
                                        row(candidate, in: recipients)
                                    }
                                } header: {
                                    sectionHeader("Everyone")
                                }
                            }
                        } else {
                            ForEach(recipients.candidates) { candidate in
                                row(candidate, in: recipients)
                            }
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
                let picker = SendToModel(
                    userAPI: environment.userAPI,
                    instantAPI: environment.instantAPI,
                    history: { environment.store.history },
                    currentUserId: environment.session.currentUserId
                )
                // Opened from an already-aimed capture: the picker is here to
                // change the recipient, so it starts on the current one rather
                // than making somebody re-pick the person they already chose.
                picker.selectedId = model.recipient?.userId
                recipients = picker
            }
            // The history may not have been fetched yet, and the picker is
            // exactly where its ordering shows. Load the list straight away and
            // let the refresh re-sort it, rather than holding the sheet empty.
            async let refreshed: Void = environment.store.refreshHistory()
            await recipients?.load()
            await refreshed
            recipients?.reorder(using: environment.store.history)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(InstantStyle.secondaryText)
            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 6, trailing: 0))
            .accessibilityIdentifier("sendTo.header.\(title)")
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
        guard let recipients, let recipientId = recipients.selectedId else { return }

        // Picking somebody here supersedes whatever the camera was aimed at, so
        // the send button and the camera's chip cannot end up naming two
        // different people if this send fails and the photo is kept.
        if recipientId != model.recipient?.userId {
            environment.clearAim()
            model.recipient = recipients.candidates
                .first { $0.id == recipientId }
                .map { InstantRecipient(userId: $0.id, name: $0.user.displayName) }
        }

        await model.send(to: recipientId)
        if case .sent = model.sendState {
            environment.clearAim()
            environment.store.noteSent(toUserId: recipientId)
            await environment.store.refreshHistory()
            dismiss()
            onSent()
        }
    }
}
#endif

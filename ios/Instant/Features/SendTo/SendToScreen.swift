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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let recipients {
                    sendBar(recipients)
                }
            }
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(.white)
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

    /// Sending sits at the bottom rather than in the far top corner.
    ///
    /// It is the one thing this screen is for, the list above it can be long
    /// enough to scroll, and the reach to a top-right toolbar button is the
    /// wrong end of the phone from the thumb that just picked somebody. It is
    /// also the same white capsule the compose screen sends with, so the two
    /// ways out of a photo look like one action.
    private func sendBar(_ recipients: SendToModel) -> some View {
        let selected = recipients.candidates.first { $0.id == recipients.selectedId }
        let isReady = selected != nil && !model.isSending

        return Button {
            Task { await send() }
        } label: {
            HStack(spacing: 8) {
                // Named once somebody is picked, so the button confirms the
                // choice rather than restating the question.
                Text(selected.map { "Send to \($0.user.displayName)" } ?? "Send")
                    .font(.system(size: 16, weight: .bold))
                if model.isSending {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Color.white))
            // `.plain` buttons do not dim themselves when disabled, and a
            // full-width white capsule that looks live but is not is worse
            // here than anywhere.
            .opacity(isReady ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .accessibilityIdentifier("sendTo.send")
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(InstantStyle.background)
        .overlay(alignment: .top) {
            // The list scrolls under this; without a line the last row looks
            // like it was cut off rather than covered.
            Rectangle()
                .fill(InstantStyle.surfaceRaised)
                .frame(height: 1)
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

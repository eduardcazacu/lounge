#if canImport(UIKit)
import SwiftUI

/// Conversations. One row per person: avatar, name with their streak beside it,
/// and whatever they have waiting.
///
/// This sits to the *left* of the camera in the pager, which is where Snapchat
/// puts chat and where the camera's own chat button points.
struct InboxScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewing: ViewerModel?
    @State private var safetyNumberPeer: InstantStore.Conversation?

    private var store: InstantStore { environment.store }

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if store.conversations.isEmpty {
                    empty
                } else {
                    List(store.conversations) { conversation in
                        conversationRow(conversation)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.refreshAll() }
                }
            }
        }
        .fullScreenCover(item: $viewing) { model in
            ViewerScreen(model: model) {
                store.dismiss(model.instant.id)
                viewing = nil
                Task { await store.refreshHistory() }
            }
        }
        .sheet(item: $safetyNumberPeer) { peer in
            SafetyNumberScreen(peerUserId: peer.userId, peerName: peer.name)
        }
        .onChange(of: environment.pendingInstantId) { _, id in
            guard let id, let instant = store.instants.first(where: { $0.id == id }) else { return }
            environment.pendingInstantId = nil
            open(instant)
        }
    }

    private var header: some View {
        HStack {
            Text("Instant")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(InstantStyle.primaryText)
            Spacer()
            connectionWarning
            Button {
                environment.showsInbox = false
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(InstantStyle.surfaceRaised))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.camera")
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 12)
    }

    /// Only shown when live delivery is actually broken.
    ///
    /// A dot that is always there is ambient noise; one that appears only when
    /// something is wrong is worth reading. It carries its own text, because an
    /// unlabelled coloured dot leaves the reader to guess.
    @ViewBuilder
    private var connectionWarning: some View {
        if let text = store.connection.warningText {
            let color: Color = store.connection.isRecoverable ? .orange : InstantStyle.secondaryText
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.14)))
            .padding(.trailing, 8)
            .accessibilityIdentifier("inbox.connection")
            .accessibilityLabel(text)
        }
    }

    /// One row per person. The streak sits beside the name rather than in its
    /// own section: it is an attribute of the conversation, not a separate list
    /// the reader has to join to this one by eye.
    private func conversationRow(_ conversation: InstantStore.Conversation) -> some View {
        Button {
            guard let instant = conversation.pending else { return }
            open(instant)
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    name: conversation.name,
                    themeKey: conversation.themeKey,
                    url: conversation.profilePictureUrl
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(conversation.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(InstantStyle.primaryText)
                        if let streak = conversation.streak {
                            StreakBadge(streak: streak)
                        }
                    }
                    status(for: conversation)
                }

                Spacer()

                if conversation.hasPending {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(InstantStyle.secondaryText)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Long press for the safety number. `simultaneousGesture` rather than
        // `onLongPressGesture` so the row's tap keeps working inside the List.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                safetyNumberPeer = conversation
            }
        )
        .listRowBackground(InstantStyle.background)
        .listRowSeparatorTint(InstantStyle.surfaceRaised)
        .accessibilityIdentifier("inbox.conversation.\(conversation.name)")
        .accessibilityHint("Press and hold to check the safety number")
    }

    @ViewBuilder
    private func status(for conversation: InstantStore.Conversation) -> some View {
        if let instant = conversation.pending {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(InstantStyle.unread)
                    .frame(width: 10, height: 10)
                Text(instant.envelope == nil ? "Can't be opened here" : "New Instant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InstantStyle.unread)
                Text(
                    conversation.pendingCount > 1
                        ? "· \(conversation.pendingCount) waiting"
                        : "· \(instant.durationMode.label)"
                )
                .font(.system(size: 13))
                .foregroundStyle(InstantStyle.secondaryText)
            }
        } else if conversation.streak?.atRisk == true {
            Text("Send one today to keep your streak")
                .font(.system(size: 13))
                .foregroundStyle(InstantStyle.unread)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundStyle(InstantStyle.secondaryText)
            Text("No conversations yet")
                .font(.headline)
                .foregroundStyle(InstantStyle.primaryText)
            Text("Swipe back to the camera and send one.")
                .font(.footnote)
                .foregroundStyle(InstantStyle.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("inbox.empty")
    }

    private func open(_ instant: InstantDelivery) {
        guard let device = store.device else { return }
        viewing = ViewerModel(instant: instant, api: environment.instantAPI, device: device)
    }
}

extension ViewerModel: @MainActor Identifiable {
    public nonisolated var id: String { instant.id }
}
#endif

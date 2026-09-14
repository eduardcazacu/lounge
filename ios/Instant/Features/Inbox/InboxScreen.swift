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

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    header.padding(.top, headerTopPadding(proxy))

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
        }
        .fullScreenCover(item: $viewing) { model in
            ViewerScreen(model: model) {
                store.dismiss(model.instant.id)
                // Closing an instant lands back here rather than on the camera,
                // with the sender's row now offering a reply — the one thing
                // somebody who has just looked at a photo is likely to want.
                // `showsInbox` is already true on every path that opens a
                // viewer; setting it is what makes that a rule rather than a
                // coincidence of how the viewer was reached.
                if model.wasSeen { store.noteOpened(senderId: model.instant.senderId) }
                environment.showsInbox = true
                viewing = nil
                Task { await store.refreshHistory() }
            }
        }
        .sheet(item: $safetyNumberPeer) { peer in
            SafetyNumberScreen(peerUserId: peer.userId, peerName: peer.name)
        }
        .onChange(of: environment.pendingInstantId) { _, _ in openPendingIfPossible() }
        // A notification tapped from a cold start arrives before the inbox has
        // been fetched, so the named instant is not here yet. Waiting for it to
        // land is the difference between the deep link working and the inbox
        // just sitting there with the instant one tap away.
        .onChange(of: store.instants) { _, _ in openPendingIfPossible() }
        .onAppear { openPendingIfPossible() }
    }

    /// The account button is pinned above the pager, so this row starts to the
    /// right of where it lands and sits on the same line as it. Anything else
    /// reads as two headers stacked on top of each other.
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
                    .frame(width: AccountButton.size, height: AccountButton.size)
                    .background(Circle().fill(InstantStyle.surfaceRaised))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox.camera")
        }
        .frame(height: AccountButton.size)
        .padding(.leading, InstantStyle.viewportInset + AccountButton.size + 12)
        .padding(.trailing, InstantStyle.viewportInset)
        .padding(.bottom, 12)
    }

    /// Drops the header onto the viewport's top line — where the pinned account
    /// button is — measured from inside the safe area, which is where this
    /// screen's content lives.
    private func headerTopPadding(_ proxy: GeometryProxy) -> CGFloat {
        let safeArea = proxy.safeAreaInsets
        let screen = CGSize(
            width: proxy.size.width + safeArea.leading + safeArea.trailing,
            height: proxy.size.height + safeArea.top + safeArea.bottom
        )
        let line = InstantStyle.viewportRect(in: screen).minY + InstantStyle.viewportInset
        return max(0, line - safeArea.top)
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
            if let instant = conversation.pending {
                open(instant)
            } else {
                // Nothing to read, so the tap means the other direction: the
                // camera, already aimed at them.
                environment.aim(
                    at: InstantRecipient(userId: conversation.userId, name: conversation.name)
                )
            }
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

                // Every row leads somewhere now, and the glyph says where: into
                // what is waiting, or out to the camera aimed at them.
                Image(systemName: conversation.hasPending ? "chevron.right" : "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        conversation.hasPending
                            ? InstantStyle.secondaryText
                            : InstantStyle.secondaryText.opacity(0.7)
                    )
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
        .accessibilityHint(
            conversation.hasPending
                ? "Press and hold to check the safety number"
                : "Opens the camera to send \(conversation.name) an instant. Press and hold to check the safety number."
        )
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
        } else if conversation.suggestsReply {
            // Ranked above the streak warning: replying keeps the streak too,
            // and this is the more specific thing to do.
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Tap to reply")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(InstantStyle.flame)
        } else if conversation.streakNeedsYourSend {
            // Only when it is actually your move. A streak lapsing because they
            // have gone quiet is not something this reader can fix, and telling
            // them to send again right after they have is just wrong.
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

    /// Opens whatever a notification asked for, once it is actually in the
    /// inbox. Stays pending until then, and is cleared once spent.
    private func openPendingIfPossible() {
        guard viewing == nil,
              let id = environment.pendingInstantId,
              let instant = store.instants.first(where: { $0.id == id })
        else { return }
        environment.pendingInstantId = nil
        open(instant)
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

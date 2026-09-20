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
    @State private var report: ReportModel?
    @State private var blockCandidate: InstantStore.Conversation?
    @State private var blockError: String?
    /// Read once per row draw so every receipt on screen is aged against the
    /// same clock, and advanced by `ageReceipts` while the inbox is up.
    @State private var now = Date()

    private var store: InstantStore { environment.store }

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    header.padding(.top, headerTopPadding(proxy))

                    if store.conversations.isEmpty {
                        if store.hasLoaded { empty } else { loading }
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
            ViewerScreen(model: model, onClose: {
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
            }, onBlocked: { environment.didBlock(userId: $0) })
        }
        .sheet(item: $report) { report in
            ReportScreen(
                model: report,
                termsURL: environment.config.webAppURL.appendingPathComponent("terms")
            ) { blocked in
                if blocked { environment.didBlock(userId: report.reportedUserId) }
            }
        }
        .confirmationDialog(
            "Block \(blockCandidate?.name ?? "them")?",
            isPresented: Binding(
                get: { blockCandidate != nil },
                set: { if !$0 { blockCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: blockCandidate
        ) { conversation in
            Button("Block", role: .destructive) { Task { await block(conversation) } }
                .accessibilityIdentifier("inbox.block.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { conversation in
            Text("You and \(conversation.name) won't be able to see or send instants to each other. Anything waiting from them is deleted. You can unblock them from your account.")
        }
        .alert(
            "Couldn't block",
            isPresented: Binding(get: { blockError != nil }, set: { if !$0 { blockError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockError ?? "")
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
        .task { await ageReceipts() }
    }

    /// A receipt is the one thing on this screen that changes with nothing
    /// happening: "sent just now" is wrong a few minutes later, and an inbox
    /// nobody has touched never redraws on its own. A minute is the resolution
    /// the phrasing has, so it is also the interval worth spending.
    private func ageReceipts() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            now = Date()
        }
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
        // Press and hold for everything about the person rather than the
        // conversation: reporting and blocking (Guideline 1.2) and the safety
        // number. A menu makes all three discoverable where a bare long press
        // hid the one it had.
        .contextMenu {
            Button {
                safetyNumberPeer = conversation
            } label: {
                Label("Safety number", systemImage: "checkmark.shield")
            }
            .accessibilityIdentifier("inbox.menu.safetyNumber")

            Button {
                report = ReportModel(
                    reportedUserId: conversation.userId,
                    reportedName: conversation.name,
                    api: environment.moderationAPI
                )
            } label: {
                Label("Report…", systemImage: "exclamationmark.bubble")
            }
            .accessibilityIdentifier("inbox.menu.report")

            Button(role: .destructive) {
                blockCandidate = conversation
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("inbox.menu.block")
        }
        .listRowBackground(InstantStyle.background)
        .listRowSeparatorTint(InstantStyle.surfaceRaised)
        .accessibilityIdentifier("inbox.conversation.\(conversation.name)")
        .accessibilityHint(
            conversation.hasPending
                ? "Press and hold to report, block, or check the safety number"
                : "Opens the camera to send \(conversation.name) an instant. Press and hold to report, block, or check the safety number."
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
        } else if let receipt = conversation.sentReceipt?.status(now: now) {
            // Last, because it is the only line here that asks for nothing. It
            // is what the row has to say when the conversation is the reader's
            // own photo sitting at the other end.
            sentStatus(receipt)
        }
    }

    /// The receipt for the last photo sent to this person. Quiet — secondary
    /// text, no colour — so it never competes with a line that wants a tap.
    private func sentStatus(_ status: InstantSendReceipt.Status) -> some View {
        let (glyph, text, spoken): (String, String, String) = switch status {
        case .waiting(let since):
            ("paperplane.fill", "Sent \(RelativeTime.short(since: since, now: now))",
             "Sent \(RelativeTime.spoken(since: since, now: now)), not opened yet")
        case .opened(let at):
            ("eye.fill", "Opened \(RelativeTime.short(since: at, now: now))",
             "Opened \(RelativeTime.spoken(since: at, now: now))")
        case .expiredUnopened:
            ("clock.badge.xmark", "Expired unopened", "Expired unopened")
        }
        return HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
        }
        .foregroundStyle(InstantStyle.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Only on a first launch, or after signing in: every later cold start
    /// draws the cached inbox instead.
    private var loading: some View {
        VStack {
            Spacer()
            ProgressView()
                .tint(InstantStyle.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("inbox.loading")
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

    private func block(_ conversation: InstantStore.Conversation) async {
        do {
            try await environment.moderationAPI.block(userId: conversation.userId)
            environment.didBlock(userId: conversation.userId)
        } catch {
            blockError = "Check your connection and try again."
        }
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

import Foundation
import Observation

/// The app's live view of Instant: what is waiting, what the streaks are, and
/// whether the realtime connection is up.
///
/// Enrollment, the socket and the inbox drain all funnel through here so there
/// is one place that owns dedup.
@MainActor
@Observable
public final class InstantStore {
    public private(set) var instants: [InstantDelivery] = []

    /// From `GET /api/v1/instant/conversations`: everyone you have talked to,
    /// whether or not a streak is running — with anything sent from this client
    /// folded in, so the order reflects a send the moment it happens rather than
    /// on the round trip that follows it.
    public var history: [InstantConversationSummary] {
        guard !sendsByUser.isEmpty else { return serverHistory }
        return serverHistory.map { entry in
            guard let sentAt = sendsByUser[entry.userId] else { return entry }
            return entry.withSend(at: sentAt)
        }
    }

    private var serverHistory: [InstantConversationSummary] = []

    /// When this client last sent to each person. Kept rather than dropped on
    /// the next refresh: `withSend` takes the later of the two marks, so a
    /// server still catching up cannot walk a send backwards.
    private var sendsByUser: [Int: String] = [:]

    /// Live streaks only, derived from the history rather than fetched
    /// separately — `/streaks` is a strict subset of what `/conversations`
    /// already returns.
    public var streaks: [InstantStreakSummary] { history.compactMap(\.streak) }
    public private(set) var connection: InstantConnectionState = .idle
    public private(set) var device: DeviceIdentity?
    public private(set) var enrollmentError: String?
    /// Set when the session is over and the UI should return to sign-in.
    public private(set) var sessionExpired = false

    /// Ids that have ever been shown. Never pruned when an instant is
    /// dismissed — that is the point: a viewed instant must not reappear when
    /// the inbox is drained again, and the inbox has no idea the client already
    /// dealt with it.
    private var seenIds: Set<String> = []

    /// People whose instant has just been opened, so their row can offer a
    /// reply rather than sitting inert.
    ///
    /// Session-scoped on purpose. The prompt is the tail end of "you just
    /// looked at their photo"; one that survived a relaunch would be a chore
    /// list rather than a nudge.
    public private(set) var replyHints: Set<Int> = []

    private let api: InstantAPIProtocol
    private let identities: DeviceIdentityProviding
    private let widgets: WidgetSnapshotPublishing
    private let makeSocket: @MainActor (InstantAPIProtocol) -> InboxSocketProtocol
    private var socket: InboxSocketProtocol?
    private var pump: Task<Void, Never>?
    private var userId: Int?

    public init(
        api: InstantAPIProtocol,
        identities: DeviceIdentityProviding,
        widgets: WidgetSnapshotPublishing = WidgetSnapshotPublisher(),
        makeSocket: @escaping @MainActor (InstantAPIProtocol) -> InboxSocketProtocol
    ) {
        self.api = api
        self.identities = identities
        self.widgets = widgets
        self.makeSocket = makeSocket
    }

    // MARK: - Widget

    /// What the home-screen widget should show: everyone with something
    /// waiting, in the order the inbox lists them.
    ///
    /// The count takes the larger of what this device holds and what the server
    /// last reported. The local list can be behind before the first drain, and
    /// the server's count can be behind an instant that just arrived over the
    /// socket; neither is reliably ahead of the other.
    func makeWidgetSnapshot(now: Date = Date()) -> InstantWidgetSnapshot {
        let serverCounts = Dictionary(
            history.map { ($0.userId, $0.unopenedCount) },
            uniquingKeysWith: max
        )
        let contacts = conversations.compactMap { conversation -> InstantWidgetSnapshot.Contact? in
            let waiting = max(conversation.pendingCount, serverCounts[conversation.userId] ?? 0)
            guard waiting > 0 else { return nil }
            return InstantWidgetSnapshot.Contact(
                userId: conversation.userId,
                name: conversation.name,
                themeKey: conversation.themeKey,
                profilePictureUrl: conversation.profilePictureUrl,
                unopenedCount: waiting,
                streakCount: conversation.streak?.count ?? 0
            )
        }
        return InstantWidgetSnapshot(contacts: contacts, updatedAt: now)
    }

    /// Republishes the widget. Cheap when nothing changed, because the publisher
    /// only rewrites what differs.
    func refreshWidget() {
        let snapshot = makeWidgetSnapshot()
        Task { [widgets] in await widgets.publish(snapshot) }
    }

    public var unreadCount: Int { instants.count }

    public func streak(withUserId userId: Int) -> InstantStreakSummary? {
        streaks.first { $0.userId == userId }
    }

    /// One row per person: whatever they have waiting, plus the streak that
    /// belongs to them.
    ///
    /// Instants and streaks arrive from two different endpoints keyed by user,
    /// and showing them as two lists made the reader join them by eye. Merging
    /// here keeps that join in one testable place.
    public struct Conversation: Identifiable, Equatable, Sendable {
        public let userId: Int
        public let name: String
        public let themeKey: String
        public let profilePictureUrl: String?
        public let streak: InstantStreakSummary?
        /// The oldest instant still waiting, which is the one to open first.
        public let pending: InstantDelivery?
        public let pendingCount: Int
        /// When this conversation was last active in either direction, from the
        /// server. Nil only for one that arrived over the socket before the
        /// first history refresh caught up.
        public let lastInteractionAt: String?
        /// Their instant has been opened and nothing has gone back yet. What is
        /// waiting still comes first where both are true — the row says one
        /// thing, and "open this" beats "answer that".
        public let suggestsReply: Bool
        /// A streak about to lapse that is waiting on *you*. One waiting on them
        /// is not something the reader can act on, so it neither nags nor jumps
        /// the queue.
        public let streakNeedsYourSend: Bool

        public var id: Int { userId }
        public var hasPending: Bool { pending != nil }
    }

    public var conversations: [Conversation] {
        var byUser: [Int: Conversation] = [:]

        // The server's history is the spine: it knows about people whose streak
        // has lapsed, or who were never mutual, and about conversations whose
        // instants have long since been swept.
        for entry in history {
            byUser[entry.userId] = Conversation(
                userId: entry.userId,
                name: entry.displayName,
                themeKey: entry.themeKey,
                profilePictureUrl: entry.profilePictureUrl,
                streak: entry.streak,
                pending: nil,
                pendingCount: 0,
                lastInteractionAt: entry.lastInteractionAt,
                suggestsReply: replyHints.contains(entry.userId),
                streakNeedsYourSend: entry.streakNeedsYourSend
            )
        }

        // Then what is actually openable *here*. The server's `unopenedCount`
        // counts every device, including instants this one has no envelope for,
        // so the local list is what decides whether a row can be tapped.
        //
        // `instants` is already in send order, so the first one seen per sender
        // is the oldest — the one that expires soonest.
        for instant in instants {
            let existing = byUser[instant.senderId]
            byUser[instant.senderId] = Conversation(
                userId: instant.senderId,
                // An instant can arrive over the socket before the history
                // refresh that would name this person, so fall back to what the
                // delivery itself carries.
                name: existing?.name ?? instant.displayName,
                themeKey: existing?.themeKey ?? instant.senderThemeKey,
                profilePictureUrl: existing?.profilePictureUrl ?? instant.senderProfilePictureUrl,
                streak: existing?.streak,
                pending: existing?.pending ?? instant,
                pendingCount: (existing?.pendingCount ?? 0) + 1,
                lastInteractionAt: existing?.lastInteractionAt ?? instant.createdAt,
                suggestsReply: existing?.suggestsReply ?? replyHints.contains(instant.senderId),
                streakNeedsYourSend: existing?.streakNeedsYourSend ?? false
            )
        }

        // Anything waiting comes first, then a streak waiting on a send from
        // you, then simply whoever you interacted with most recently — in
        // either direction, so somebody you have just sent to leads somebody
        // who sent to you an hour ago.
        return byUser.values.sorted { lhs, rhs in
            if lhs.hasPending != rhs.hasPending { return lhs.hasPending }
            if lhs.streakNeedsYourSend != rhs.streakNeedsYourSend {
                return lhs.streakNeedsYourSend
            }
            let lhsSeen = lhs.lastInteractionAt ?? ""
            let rhsSeen = rhs.lastInteractionAt ?? ""
            if lhsSeen != rhsSeen { return lhsSeen > rhsSeen }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Lifecycle

    /// Enrolls this device and brings the connection up. Safe to call on every
    /// launch and on every foreground: registration is an upsert.
    public func start(userId: Int) async {
        if self.userId != userId {
            reset()
            self.userId = userId
        }

        let identity: DeviceIdentity
        do {
            identity = try identities.identity(forUserId: userId)
        } catch {
            enrollmentError = "This device could not create an Instant identity."
            return
        }
        device = identity

        do {
            _ = try await api.registerDevice(
                deviceId: identity.deviceId,
                publicKey: identity.publicKeyBase64
            )
            enrollmentError = nil
        } catch let error as APIError where error.isAuthFailure {
            sessionExpired = true
            return
        } catch {
            enrollmentError = "Could not register this device with Instant."
            // Still connect: the key may already be registered from a previous
            // launch, in which case everything works.
        }

        guard socket == nil else { return }
        let socket = makeSocket(api)
        self.socket = socket
        pump = Task { [weak self] in
            for await event in socket.events {
                await self?.handle(event, deviceId: identity.deviceId)
            }
        }
        socket.start(deviceId: identity.deviceId)
    }

    public func stop() {
        socket?.stop()
        pump?.cancel()
        pump = nil
        socket = nil
        connection = .idle
    }

    public func reset() {
        stop()
        instants = []
        serverHistory = []
        sendsByUser = [:]
        // Signing out must not leave a stranger's name on the home screen.
        Task { [widgets] in await widgets.clear() }
        seenIds = []
        replyHints = []
        device = nil
        userId = nil
        enrollmentError = nil
        sessionExpired = false
    }

    // MARK: - Events

    func handle(_ event: InboxSocketEvent, deviceId: String) async {
        switch event {
        case .state(let state):
            connection = state
            if state == .unsupported {
                // No Durable Object. Nothing will be pushed, so poll instead of
                // leaving the inbox permanently stale.
                await refreshInbox(deviceId: deviceId)
            }
        case .shouldDrainInbox:
            await refreshInbox(deviceId: deviceId)
            await refreshHistory()
        case .wire(.ready):
            break
        case .wire(.instant(let instant)):
            merge([instant])
            await refreshHistory()
        case .wire(.opened):
            // The sender's read receipt. Streak state may have moved with it.
            await refreshHistory()
        }
    }

    /// Adds anything not seen before, keeping the list in send order.
    ///
    /// The seen-set is updated outside any observable mutation so a re-entrant
    /// call cannot see a half-applied state — the web client had a bug of
    /// exactly that shape, where StrictMode double-invoked the updater and the
    /// second pass found every id already marked and dropped the batch.
    func merge(_ incoming: [InstantDelivery]) {
        let fresh = incoming.filter { !seenIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for instant in fresh { seenIds.insert(instant.id) }
        instants = (instants + fresh).sorted { $0.createdAt < $1.createdAt }
        refreshWidget()
    }

    public func refreshInbox(deviceId: String) async {
        do {
            merge(try await api.inbox(deviceId: deviceId))
        } catch let error as APIError where error.isAuthFailure {
            sessionExpired = true
        } catch {
            // Transient. The socket will drain again on its next attempt.
        }
    }

    /// Seam for tests and for anything that already holds fresh history.
    func applyHistory(_ history: [InstantConversationSummary]) {
        serverHistory = history
    }

    public func refreshHistory() async {
        do {
            serverHistory = try await api.conversations()
            refreshWidget()
        } catch let error as APIError where error.isAuthFailure {
            sessionExpired = true
        } catch {}
    }

    public func refreshAll() async {
        guard let deviceId = device?.deviceId else { return }
        await refreshInbox(deviceId: deviceId)
        await refreshHistory()
    }

    /// Removes an instant from the waiting list once it has been opened,
    /// expired, or turned out to be unopenable. It stays in the seen-set.
    public func dismiss(_ id: String) {
        // Captured before removal: the server's count for this person is now
        // stale by one, and until the next history refresh lands, taking the
        // larger of the two counts would keep the widget claiming mail that has
        // already been read. Over-reporting is the worse failure — it sends you
        // into the app to find nothing.
        let senderId = instants.first { $0.id == id }?.senderId
        instants.removeAll { $0.id == id }
        if let senderId {
            serverHistory = serverHistory.map { entry in
                entry.userId == senderId
                    ? entry.withUnopenedCount(entry.unopenedCount - 1)
                    : entry
            }
        }
        refreshWidget()
    }

    /// Records that something from this person has actually been seen, which is
    /// the moment a reply is most likely. Paired with `dismiss`, which is also
    /// called for an instant that was already gone or could not be decrypted —
    /// neither of which anyone opened, so neither earns a prompt.
    public func noteOpened(senderId: Int) {
        replyHints.insert(senderId)
    }

    /// Records an instant this client has just sent.
    ///
    /// Two things happen on a send, and both have to be visible before the
    /// server is asked again: the conversation becomes the most recent one in
    /// either direction, and a reply prompt from them is answered.
    public func noteSent(toUserId userId: Int, at now: Date = Date()) {
        sendsByUser[userId] = WireTimestamp.string(from: now)
        replyHints.remove(userId)
        refreshWidget()
    }

    public func clearSessionExpired() {
        sessionExpired = false
    }
}

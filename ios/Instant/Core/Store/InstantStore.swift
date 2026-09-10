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
    public private(set) var streaks: [InstantStreakSummary] = []
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

    private let api: InstantAPIProtocol
    private let identities: DeviceIdentityProviding
    private let recentContacts: RecentContactsStoring
    private let makeSocket: @MainActor (InstantAPIProtocol) -> InboxSocketProtocol
    private var socket: InboxSocketProtocol?
    private var pump: Task<Void, Never>?
    private var userId: Int?

    public init(
        api: InstantAPIProtocol,
        identities: DeviceIdentityProviding,
        recentContacts: RecentContactsStoring = RecentContactsStore(),
        makeSocket: @escaping @MainActor (InstantAPIProtocol) -> InboxSocketProtocol
    ) {
        self.api = api
        self.identities = identities
        self.recentContacts = recentContacts
        self.makeSocket = makeSocket
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

        public var id: Int { userId }
        public var hasPending: Bool { pending != nil }
    }

    public var conversations: [Conversation] {
        var byUser: [Int: Conversation] = [:]

        // `instants` is already in send order, so the first one seen per sender
        // is the oldest — the one that expires soonest.
        for instant in instants {
            let existing = byUser[instant.senderId]
            byUser[instant.senderId] = Conversation(
                userId: instant.senderId,
                name: instant.displayName,
                themeKey: instant.senderThemeKey,
                profilePictureUrl: instant.senderProfilePictureUrl,
                streak: streak(withUserId: instant.senderId),
                pending: existing?.pending ?? instant,
                pendingCount: (existing?.pendingCount ?? 0) + 1
            )
        }

        for streak in streaks where byUser[streak.userId] == nil {
            byUser[streak.userId] = Conversation(
                userId: streak.userId,
                name: streak.displayName,
                themeKey: streak.themeKey,
                profilePictureUrl: streak.profilePictureUrl,
                streak: streak,
                pending: nil,
                pendingCount: 0
            )
        }

        // Anything waiting comes first; then whoever is closest to losing a
        // streak, since that is the only other thing on this screen that is
        // time-sensitive.
        return byUser.values.sorted { lhs, rhs in
            if lhs.hasPending != rhs.hasPending { return lhs.hasPending }
            let lhsRisk = lhs.streak?.atRisk ?? false
            let rhsRisk = rhs.streak?.atRisk ?? false
            if lhsRisk != rhsRisk { return lhsRisk }
            let lhsCount = lhs.streak?.count ?? 0
            let rhsCount = rhs.streak?.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
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
        streaks = []
        seenIds = []
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
            await refreshStreaks()
        case .wire(.ready):
            break
        case .wire(.instant(let instant)):
            merge([instant])
            await refreshStreaks()
        case .wire(.opened):
            // The sender's read receipt. Streak state may have moved with it.
            await refreshStreaks()
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

        // Receiving counts as talking to someone, so it feeds the picker's
        // ordering. The instant's own timestamp is used rather than "now": a
        // backlog drained after a week offline should not all read as current.
        if let userId {
            for instant in fresh {
                let when = InstantTimestamp.parse(instant.createdAt) ?? Date()
                recentContacts.record(peerUserId: instant.senderId, for: userId, at: when)
            }
        }
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

    /// Seam for tests and for anything that already holds fresh streak data.
    func applyStreaks(_ streaks: [InstantStreakSummary]) {
        self.streaks = streaks
    }

    public func refreshStreaks() async {
        do {
            streaks = try await api.streaks()
        } catch let error as APIError where error.isAuthFailure {
            sessionExpired = true
        } catch {}
    }

    public func refreshAll() async {
        guard let deviceId = device?.deviceId else { return }
        await refreshInbox(deviceId: deviceId)
        await refreshStreaks()
    }

    /// Removes an instant from the waiting list once it has been opened,
    /// expired, or turned out to be unopenable. It stays in the seen-set.
    public func dismiss(_ id: String) {
        instants.removeAll { $0.id == id }
    }

    public func clearSessionExpired() {
        sessionExpired = false
    }
}

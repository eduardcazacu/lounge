import Foundation

// Swift mirrors of the wire types in common/src/index.ts and the handlers in
// backend/src/route/. Field names match the JSON exactly, so no CodingKeys.

public enum InstantDurationMode: String, Codable, CaseIterable, Sendable {
    case oneSecond = "1s"
    case fiveSeconds = "5s"
    case infinite
    /// A video plays through once and closes.
    case playOnce = "once"
    /// A video plays round until it is closed.
    case loop

    /// Tolerant, unlike the synthesised decoder. One instant carrying a mode
    /// this build has never heard of would otherwise fail the decode of the
    /// whole inbox — every row, not just that one — which is exactly what the
    /// builds from before video do. An unknown mode reads as the default.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstantDurationMode(rawValue: raw) ?? .fiveSeconds
    }

    /// `InstantViewer.tsx`: {"1s": 1000, "5s": 5000, infinite: null}. The
    /// video modes have no clock of their own: playback is the clock.
    public var duration: Duration? {
        switch self {
        case .oneSecond: return .seconds(1)
        case .fiveSeconds: return .seconds(5)
        case .infinite, .playOnce, .loop: return nil
        }
    }

    public var isVideoMode: Bool {
        self == .playOnce || self == .loop
    }

    public var label: String {
        switch self {
        case .oneSecond: return "1s"
        case .fiveSeconds: return "5s"
        case .infinite: return "∞"
        case .playOnce: return "Once"
        case .loop: return "Loop"
        }
    }

    /// Cycles within its own family. The two never mix: the server refuses a
    /// photo marked to loop, and a video has no meaning for one second.
    public var next: InstantDurationMode {
        switch self {
        case .oneSecond: return .fiveSeconds
        case .fiveSeconds: return .infinite
        case .infinite: return .oneSecond
        case .playOnce: return .loop
        case .loop: return .playOnce
        }
    }
}

public struct InstantKeyEnvelope: Codable, Equatable, Sendable {
    public let wrappedKey: String
    public let wrapIv: String

    public init(wrappedKey: String, wrapIv: String) {
        self.wrappedKey = wrappedKey
        self.wrapIv = wrapIv
    }
}

public struct InstantDelivery: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let senderId: Int
    public let senderName: String?
    public let senderThemeKey: String
    public let senderProfilePictureUrl: String?
    public let mediaType: String
    public let mediaIv: String
    public let ephemeralPubKey: String
    public let byteSize: Int
    public let durationMode: InstantDurationMode
    public let createdAt: String
    public let expiresAt: String
    /// `nil` means no wrapped key exists for this device — the identity was
    /// replaced after the sender wrapped. The instant can never be opened here.
    public let envelope: InstantKeyEnvelope?

    public var displayName: String { senderName ?? "Someone" }

    public init(
        id: String,
        senderId: Int,
        senderName: String?,
        senderThemeKey: String,
        senderProfilePictureUrl: String?,
        mediaType: String,
        mediaIv: String,
        ephemeralPubKey: String,
        byteSize: Int,
        durationMode: InstantDurationMode,
        createdAt: String,
        expiresAt: String,
        envelope: InstantKeyEnvelope?
    ) {
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.senderThemeKey = senderThemeKey
        self.senderProfilePictureUrl = senderProfilePictureUrl
        self.mediaType = mediaType
        self.mediaIv = mediaIv
        self.ephemeralPubKey = ephemeralPubKey
        self.byteSize = byteSize
        self.durationMode = durationMode
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.envelope = envelope
    }
}

public struct InstantStreakSummary: Codable, Equatable, Sendable, Identifiable {
    public let userId: Int
    public let name: String?
    public let themeKey: String
    public let profilePictureUrl: String?
    public let count: Int
    public let deadline: String?
    public let atRisk: Bool

    public var id: Int { userId }
    public var displayName: String { name ?? "Someone" }
}

/// The sender's side of a photo: when it went, and whether it has been taken.
///
/// `openedAt` is the server's own mark — the moment the recipient's device
/// claimed the media and it stopped existing anywhere — and not the `viewedAt`
/// the viewer posts back afterwards, which is a call a client that died
/// mid-view never makes.
public struct InstantSendReceipt: Codable, Equatable, Sendable {
    public let sentAt: String
    /// Nil while it is still waiting to be opened.
    public let openedAt: String?
    /// 24 hours after it was sent, when an unopened one is swept.
    public let expiresAt: String

    public init(sentAt: String, openedAt: String?, expiresAt: String) {
        self.sentAt = sentAt
        self.openedAt = openedAt
        self.expiresAt = expiresAt
    }

    public enum Status: Equatable, Sendable {
        /// Delivered and not opened yet, with when it went.
        case waiting(since: Date)
        case opened(at: Date)
        /// The 24 hours ran out and nobody looked. The most informative of the
        /// three, and the reason the window outlives the photo.
        case expiredUnopened
    }

    /// How long a receipt is worth showing. Past this the photo is long gone
    /// either way and the row has nothing to add.
    ///
    /// The server stops reporting a receipt at about the same age. Neither side
    /// depends on the other's exact number — whichever is shorter is the one
    /// that shows, and this one also covers a send this client recorded
    /// locally and the server has not answered for.
    public static let displayWindow: TimeInterval = 48 * 60 * 60

    /// What there is to say about it, or nil when there is nothing worth saying.
    public func status(now: Date = Date()) -> Status? {
        guard let sentAt = WireTimestamp.date(from: sentAt),
              now.timeIntervalSince(sentAt) < Self.displayWindow
        else { return nil }
        if let openedAt, let opened = WireTimestamp.date(from: openedAt) {
            return .opened(at: opened)
        }
        guard let expiresAt = WireTimestamp.date(from: expiresAt), expiresAt > now else {
            return .expiredUnopened
        }
        return .waiting(since: sentAt)
    }
}

/// One person you have exchanged instants with, from
/// `GET /api/v1/instant/conversations`.
///
/// Richer than `InstantStreakSummary` and, crucially, present whether or not a
/// streak is running — a lapsed one still has a conversation.
public struct InstantConversationSummary: Codable, Equatable, Sendable, Identifiable {
    public let userId: Int
    public let name: String?
    public let themeKey: String
    public let profilePictureUrl: String?
    public let lastInteractionAt: String
    public let lastSentAt: String?
    public let lastReceivedAt: String?
    public let unopenedCount: Int
    /// The newest photo *you* sent them, while it is recent enough to report
    /// on. Optional rather than merely nullable: an inbox cached by an older
    /// build has no such key, and a required one would fail the whole decode
    /// and lose the cold-start inbox.
    public let lastSentReceipt: InstantSendReceipt?
    /// 0 once a streak has lapsed; the conversation stays either way.
    public let streakCount: Int
    public let streakDeadline: String?
    public let streakAtRisk: Bool

    public var id: Int { userId }
    public var displayName: String { name ?? "Someone" }

    /// A copy carrying a send this client has just made.
    ///
    /// Both marks move, because both are read: `lastInteractionAt` is what the
    /// inbox orders by, and `lastSentAt` is how it knows whether a streak about
    /// to lapse is still waiting on you. `max` rather than assignment — the
    /// server's view of the same conversation can come back a moment stale, and
    /// a refresh must never undo a send that has already happened.
    public func withSend(at timestamp: String) -> InstantConversationSummary {
        InstantConversationSummary(
            userId: userId, name: name, themeKey: themeKey,
            profilePictureUrl: profilePictureUrl,
            lastInteractionAt: max(lastInteractionAt, timestamp),
            lastSentAt: max(lastSentAt ?? timestamp, timestamp),
            lastReceivedAt: lastReceivedAt,
            unopenedCount: unopenedCount,
            lastSentReceipt: receipt(forSendAt: timestamp),
            streakCount: streakCount, streakDeadline: streakDeadline,
            streakAtRisk: streakAtRisk
        )
    }

    /// The receipt for a send this client has just made, which the server has
    /// not answered for yet: nothing newer can have been opened, so it is
    /// waiting by definition. The server's own receipt wins as soon as it
    /// catches up — it is the only side that can say the photo has been taken.
    private func receipt(forSendAt timestamp: String) -> InstantSendReceipt? {
        if let lastSentReceipt, lastSentReceipt.sentAt >= timestamp {
            return lastSentReceipt
        }
        guard let sentAt = WireTimestamp.date(from: timestamp) else { return lastSentReceipt }
        return InstantSendReceipt(
            sentAt: timestamp,
            openedAt: nil,
            // The wire's own rule: an unopened instant is swept 24 hours on.
            expiresAt: WireTimestamp.string(from: sentAt.addingTimeInterval(24 * 60 * 60))
        )
    }

    /// Whether keeping this streak alive is your move.
    ///
    /// The deadline is set by whichever side went quiet first, so a streak about
    /// to lapse because *they* have not sent in a day is not a thing to nag the
    /// reader about — and not a reason to float their row over somebody the
    /// reader just sent to.
    public var streakNeedsYourSend: Bool {
        guard streakAtRisk else { return false }
        guard let lastSentAt else { return true }
        guard let lastReceivedAt else { return false }
        return lastSentAt < lastReceivedAt
    }

    /// A copy with a different waiting count, for optimistic updates.
    public func withUnopenedCount(_ count: Int) -> InstantConversationSummary {
        InstantConversationSummary(
            userId: userId, name: name, themeKey: themeKey,
            profilePictureUrl: profilePictureUrl,
            lastInteractionAt: lastInteractionAt,
            lastSentAt: lastSentAt, lastReceivedAt: lastReceivedAt,
            unopenedCount: max(0, count),
            lastSentReceipt: lastSentReceipt,
            streakCount: streakCount, streakDeadline: streakDeadline,
            streakAtRisk: streakAtRisk
        )
    }

    /// The streak view of this conversation, or nil when there is no live one.
    public var streak: InstantStreakSummary? {
        guard streakCount > 0 else { return nil }
        return InstantStreakSummary(
            userId: userId,
            name: name,
            themeKey: themeKey,
            profilePictureUrl: profilePictureUrl,
            count: streakCount,
            deadline: streakDeadline,
            atRisk: streakAtRisk
        )
    }

    public init(
        userId: Int, name: String?, themeKey: String, profilePictureUrl: String?,
        lastInteractionAt: String, lastSentAt: String?, lastReceivedAt: String?,
        unopenedCount: Int, lastSentReceipt: InstantSendReceipt?,
        streakCount: Int, streakDeadline: String?, streakAtRisk: Bool
    ) {
        self.userId = userId
        self.name = name
        self.themeKey = themeKey
        self.profilePictureUrl = profilePictureUrl
        self.lastInteractionAt = lastInteractionAt
        self.lastSentAt = lastSentAt
        self.lastReceivedAt = lastReceivedAt
        self.unopenedCount = unopenedCount
        self.lastSentReceipt = lastSentReceipt
        self.streakCount = streakCount
        self.streakDeadline = streakDeadline
        self.streakAtRisk = streakAtRisk
    }
}

struct ConversationsResponse: Codable { let conversations: [InstantConversationSummary] }

/// The wire's timestamp spelling, for the cases where the client writes one
/// instead of reading it: a send it has just made, and "now" to compare an
/// expiry against.
///
/// Matches the server's `Date.toISOString()` — milliseconds and a `Z` — because
/// these are compared as plain strings. The same instant spelled differently
/// would sort wrongly against everything that came from the server.
public enum WireTimestamp {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// The other direction, for the few places that need to measure a wire
    /// timestamp against the clock rather than compare it with another one.
    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

public struct InstantDeviceKeyDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let deviceId: String
    public let publicKey: String
    public let createdAt: String?
}

// MARK: - WebSocket frames (server -> client)

public enum InstantWireEvent: Equatable, Sendable {
    case ready(deviceId: String)
    case instant(InstantDelivery)
    case opened(instantId: String, recipientId: Int, openedAt: String)

    private struct TypeProbe: Decodable { let type: String }
    private struct Ready: Decodable { let deviceId: String }
    private struct Wrapped: Decodable { let instant: InstantDelivery }
    private struct Opened: Decodable {
        let instantId: String
        let recipientId: Int
        let openedAt: String
    }

    /// Returns nil for anything unrecognised, including the bare `pong` string
    /// the Durable Object's auto-response sends — that is not JSON and must not
    /// be treated as a decode failure.
    public static func decode(from data: Data) -> InstantWireEvent? {
        guard let probe = try? JSONDecoder().decode(TypeProbe.self, from: data) else { return nil }
        switch probe.type {
        case "ready":
            return (try? JSONDecoder().decode(Ready.self, from: data)).map { .ready(deviceId: $0.deviceId) }
        case "instant":
            return (try? JSONDecoder().decode(Wrapped.self, from: data)).map { .instant($0.instant) }
        case "opened":
            return (try? JSONDecoder().decode(Opened.self, from: data)).map {
                .opened(instantId: $0.instantId, recipientId: $0.recipientId, openedAt: $0.openedAt)
            }
        default:
            return nil
        }
    }
}

// MARK: - Responses

struct SignInResponse: Codable { let token: String }
struct WSTicketResponse: Codable { let ticket: String; let expiresIn: Int }
struct InboxResponse: Codable { let instants: [InstantDelivery] }
struct StreaksResponse: Codable { let streaks: [InstantStreakSummary] }
struct DeviceResponse: Codable { let device: InstantDeviceKeyDTO }
struct ViewedResponse: Codable { let ok: Bool; let viewedAt: String? }

struct InstantKeysResponse: Codable {
    let userId: Int
    let devices: [InstantDeviceKeyDTO]
    let myDevices: [InstantDeviceKeyDTO]
}

struct CreateInstantResponse: Codable {
    struct Created: Codable {
        let id: String
        let createdAt: String
        let expiresAt: String
        let delivered: Bool
    }
    let instant: Created
}

public struct UserSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String?
    public let themeKey: String
    public let profilePictureUrl: String?

    public var displayName: String { name ?? "Someone" }
}

struct UserListResponse: Codable { let users: [UserSummary] }

public struct AccountProfile: Codable, Equatable, Sendable {
    public let id: Int
    public let email: String
    public let name: String?
    public let bio: String?
    public let themeKey: String
    public let notificationsEnabled: Bool
    public let profilePictureKey: String?
    public let isAdmin: Bool
    public let profilePictureUrl: String?
    /// When the Community Guidelines were agreed to. `nil` means the app must
    /// ask before letting this person in. Last and defaulted so an older
    /// payload without it still decodes.
    public var termsAcceptedAt: String? = nil
}

struct MeResponse: Codable { let user: AccountProfile }

/// `PUT /user/me` answers with a narrower object than `GET /user/me` — no
/// email, notificationsEnabled or isAdmin.
public struct UpdatedProfile: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String?
    public let bio: String?
    public let themeKey: String
    public let profilePictureKey: String?
    public let profilePictureUrl: String?
}

struct UpdateProfileResponse: Codable { let user: UpdatedProfile }
struct NotificationsResponse: Codable { let notificationsEnabled: Bool }
struct ProfilePictureResponse: Codable { let key: String; let profilePictureUrl: String? }

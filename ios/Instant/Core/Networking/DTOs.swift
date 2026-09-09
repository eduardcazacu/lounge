import Foundation

// Swift mirrors of the wire types in common/src/index.ts and the handlers in
// backend/src/route/. Field names match the JSON exactly, so no CodingKeys.

public enum InstantDurationMode: String, Codable, CaseIterable, Sendable {
    case oneSecond = "1s"
    case fiveSeconds = "5s"
    case infinite

    /// `InstantViewer.tsx`: {"1s": 1000, "5s": 5000, infinite: null}.
    public var duration: Duration? {
        switch self {
        case .oneSecond: return .seconds(1)
        case .fiveSeconds: return .seconds(5)
        case .infinite: return nil
        }
    }

    public var label: String {
        switch self {
        case .oneSecond: return "1s"
        case .fiveSeconds: return "5s"
        case .infinite: return "∞"
        }
    }

    public var next: InstantDurationMode {
        switch self {
        case .oneSecond: return .fiveSeconds
        case .fiveSeconds: return .infinite
        case .infinite: return .oneSecond
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

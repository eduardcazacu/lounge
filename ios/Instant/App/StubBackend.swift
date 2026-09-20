#if canImport(UIKit)
import CryptoKit
import Foundation
import os
import UIKit

/// Canned responses for the UI tests. Real crypto, fake network: the stub seals
/// an actual instant for the app's own device key, so the viewer exercises the
/// same decrypt path it would in production.
enum StubBackend {
    /// HS256 header/payload with a throwaway signature. Only the `id` claim is
    /// ever read client-side, and nothing here reaches a real server.
    static let token: String = {
        let header = Base64URL.encode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = Base64URL.encode(Data(#"{"id":1,"exp":4102444800}"#.utf8))
        return "\(header).\(payload).stub"
    }()

    /// Timestamps are relative to now. A fixed future date (the old
    /// "2030-01-01") is not just unrealistic — anything that orders by recency
    /// sees it as newer than everything real, which quietly inverted the
    /// recipient picker under test.
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func name(forUserId id: Int) -> String {
        [1: "Tester", 2: "Ana", 3: "Bo", 4: "Cass", 5: "Dee"][id] ?? "Someone"
    }

    static func timestamp(offsetBySeconds offset: TimeInterval) -> String {
        iso.string(from: Date().addingTimeInterval(offset))
    }

    /// An hour ago, so a contact seeded at "now" is unambiguously more recent.
    static var receivedAt: String { timestamp(offsetBySeconds: -3600) }
    static var expiresAt: String { timestamp(offsetBySeconds: 23 * 3600) }

    static let senderId = 2
    static let instantId = "11111111-2222-3333-4444-555555555555"

    static func cameraFrame() -> UIImage {
        let size = CGSize(width: 1080, height: 1920)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 240, y: 700, width: 600, height: 520))
        }
    }

    static func photo() -> UIImage {
        let size = CGSize(width: 720, height: 1280)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Serves `StubBackend` responses through the same `APIClientProtocol` the real
/// client implements, so nothing above this line knows it is being stubbed.
final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
    struct State {
        var deviceKeys: [InstantDeviceKeyDTO] = []
        var sealed: (ciphertext: Data, delivery: InstantDelivery)?
        var mediaFetched = false
        var sentInstants: [Data] = []
        var termsAcceptedAt: String? = LaunchOptions.termsPending
            ? nil
            : StubBackend.timestamp(offsetBySeconds: -86_400)
        var blockedUserIds: [Int] = []
        /// Raw `payload` parts, kept as bytes so the state stays Sendable.
        var reports: [Data] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var sentInstants: [Data] { state.withLock { $0.sentInstants } }

    func data(for request: APIRequest) async throws -> Data {
        if request.method == "POST", request.path == "api/v1/instant" {
            try await sendBehaviour()
        }
        return try state.withLock { try respond(to: request, state: &$0) }
    }

    private let sendAttempts = OSAllocatedUnfairLock(initialState: 0)

    /// How the upload misbehaves, per launch argument, so the outbox's progress,
    /// failure and force-quit paths can each be seen.
    private func sendBehaviour() async throws {
        let attempt = sendAttempts.withLock { count in
            count += 1
            return count
        }
        if LaunchOptions.stallsSend {
            // Never answers; the test kills the app mid-upload.
            try await Task.sleep(for: .seconds(3600))
        }
        if let delay = LaunchOptions.sendDelay {
            try await Task.sleep(for: .seconds(delay))
        }
        if LaunchOptions.failsFirstSend, attempt == 1 {
            throw APIError(status: 503, message: "The server is busy. Try again.")
        }
    }

    private func respond(to request: APIRequest, state: inout State) throws -> Data {
        let path = request.path

        switch (request.method, path) {
        case ("POST", "api/v1/user/signin"):
            guard let body = request.jsonBody,
                  (body["password"] as? String) == "correct-horse"
            else {
                throw APIError(status: 403, message: "Incorrect credentials")
            }
            return try encode(["token": StubBackend.token])

        case ("GET", "api/v1/user/me"):
            return try encode([
                "user": [
                    "id": 1, "email": "tester@example.com", "name": "Tester",
                    "bio": "Testing Instant", "themeKey": "ocean",
                    "notificationsEnabled": true, "isAdmin": false,
                    "profilePictureKey": NSNull(), "profilePictureUrl": NSNull(),
                    // Already agreed unless a test asks to see the gate.
                    "termsAcceptedAt": state.termsAcceptedAt.map { $0 as Any } ?? NSNull(),
                ],
            ])

        case ("POST", "api/v1/user/me/accept-terms"):
            state.termsAcceptedAt = StubBackend.timestamp(offsetBySeconds: 0)
            return try encode(["termsAcceptedAt": state.termsAcceptedAt ?? NSNull()])

        case ("POST", "api/v1/user/me/delete"):
            guard (request.jsonBody?["password"] as? String) == "correct-horse" else {
                throw APIError(status: 400, message: "That password is not correct.")
            }
            return try encode(["msg": "Your account has been deleted."])

        case ("GET", "api/v1/moderation/blocks"):
            return try encode([
                "blocks": state.blockedUserIds.map { id in
                    [
                        "userId": id, "name": StubBackend.name(forUserId: id), "themeKey": "rose",
                        "profilePictureUrl": NSNull(), "blockedAt": StubBackend.timestamp(offsetBySeconds: 0),
                    ] as [String: Any]
                },
            ])

        case ("POST", "api/v1/moderation/blocks"):
            if let id = request.jsonBody?["userId"] as? Int, !state.blockedUserIds.contains(id) {
                state.blockedUserIds.append(id)
            }
            return try encode(["ok": true])

        case ("POST", "api/v1/moderation/reports"):
            if case .multipart(let parts) = request.body,
               let payload = parts.first(where: { $0.name == "payload" }),
               let json = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any] {
                state.reports.append(payload.data)
                if (json["alsoBlock"] as? Bool) != false, let id = json["reportedUserId"] as? Int,
                   !state.blockedUserIds.contains(id) {
                    state.blockedUserIds.append(id)
                }
            }
            return try encode(["report": ["id": state.reports.count], "blocked": true])

        case ("GET", "api/v1/user/list"):
            let users: [[String: Any]] = [
                    ["id": 1, "name": "Tester", "themeKey": "ocean", "profilePictureUrl": NSNull()],
                    ["id": 2, "name": "Ana", "themeKey": "rose", "profilePictureUrl": NSNull()],
                    ["id": 3, "name": "Bo", "themeKey": "forest", "profilePictureUrl": NSNull()],
                    // No history with this one, so the picker has an "Everyone"
                    // section to put somebody in.
                    ["id": 4, "name": "Cass", "themeKey": "gold", "profilePictureUrl": NSNull()],
                    ["id": 5, "name": "Dee", "themeKey": "indigo", "profilePictureUrl": NSNull()],
            ]
            return try encode([
                "users": users.filter { !state.blockedUserIds.contains($0["id"] as? Int ?? 0) },
            ])

        case ("PUT", "api/v1/user/me"):
            return try encode([
                "user": [
                    "id": 1, "name": "Tester",
                    "bio": (request.jsonBody?["bio"] as? String) ?? "",
                    "themeKey": (request.jsonBody?["themeKey"] as? String) ?? "ocean",
                    "profilePictureKey": NSNull(), "profilePictureUrl": NSNull(),
                ],
            ])

        case ("PUT", "api/v1/user/me/notifications"):
            return try encode([
                "notificationsEnabled": (request.jsonBody?["notificationsEnabled"] as? Bool) ?? true
            ])

        case ("POST", "api/v1/instant/keys"):
            let deviceId = request.jsonBody?["deviceId"] as? String ?? ""
            let publicKey = request.jsonBody?["publicKey"] as? String ?? ""
            let device = InstantDeviceKeyDTO(
                id: 1, deviceId: deviceId, publicKey: publicKey, createdAt: nil
            )
            state.deviceKeys = [device]
            try sealPendingInstant(for: device, state: &state)
            return try JSONEncoder().encode(DeviceResponse(device: device))

        case ("GET", "api/v1/instant/inbox"):
            let pending = state.mediaFetched ? [] : [state.sealed?.delivery].compactMap { $0 }
            return try JSONEncoder().encode(InboxResponse(instants: pending))

        case ("GET", "api/v1/instant/conversations"):
            let conversations: [[String: Any]] = [
                    // A live streak, with something waiting. Sent to 21 hours
                    // ago and received from an hour ago: a nine-day streak
                    // means both sides have sent, and which side sent longer
                    // ago is what decides whose move it is.
                    [
                        "userId": 2, "name": "Ana", "themeKey": "rose",
                        "profilePictureUrl": NSNull(),
                        "lastInteractionAt": StubBackend.receivedAt,
                        "lastSentAt": StubBackend.timestamp(offsetBySeconds: -21 * 3600),
                        "lastReceivedAt": StubBackend.receivedAt,
                        "unopenedCount": state.mediaFetched ? 0 : 1,
                        // A receipt that must stay hidden: what is waiting from
                        // her, and then the reply her opened photo asks for,
                        // both outrank the last one sent the other way.
                        "lastSentReceipt": [
                            "sentAt": StubBackend.timestamp(offsetBySeconds: -21 * 3600),
                            "openedAt": StubBackend.timestamp(offsetBySeconds: -20 * 3600),
                            "expiresAt": StubBackend.timestamp(offsetBySeconds: 3 * 3600),
                        ],
                        "streakCount": 9,
                        "streakDeadline": StubBackend.expiresAt, "streakAtRisk": true,
                    ],
                    // A streak about to lapse on *this* side, with nothing
                    // waiting: the one row that asks for a send.
                    [
                        "userId": 5, "name": "Dee", "themeKey": "indigo",
                        "profilePictureUrl": NSNull(),
                        "lastInteractionAt": StubBackend.timestamp(offsetBySeconds: -2 * 3600),
                        "lastSentAt": StubBackend.timestamp(offsetBySeconds: -23 * 3600),
                        "lastReceivedAt": StubBackend.timestamp(offsetBySeconds: -2 * 3600),
                        "unopenedCount": 0,
                        // Sent just before the streak went quiet and still not
                        // opened — the line asking for a send outranks it.
                        "lastSentReceipt": [
                            "sentAt": StubBackend.timestamp(offsetBySeconds: -23 * 3600),
                            "openedAt": NSNull(),
                            "expiresAt": StubBackend.timestamp(offsetBySeconds: 3600),
                        ],
                        "streakCount": 12,
                        "streakDeadline": StubBackend.timestamp(offsetBySeconds: 3600),
                        "streakAtRisk": true,
                    ],
                    // The case this endpoint exists for: talked to once, streak
                    // long lapsed, nothing waiting. `/streaks` would drop them.
                    [
                        "userId": 3, "name": "Bo", "themeKey": "forest",
                        "profilePictureUrl": NSNull(),
                        "lastInteractionAt": StubBackend.timestamp(offsetBySeconds: -86_400 * 30),
                        "lastSentAt": StubBackend.timestamp(offsetBySeconds: -86_400 * 30),
                        "lastReceivedAt": NSNull(),
                        "unopenedCount": 0,
                        // A month ago is well past the receipt window, so the
                        // row says nothing until this session sends to him.
                        "lastSentReceipt": NSNull(),
                        "streakCount": 0,
                        "streakDeadline": NSNull(), "streakAtRisk": false,
                    ],
            ]
            // A block hides the conversation, as the real endpoint does.
            return try encode([
                "conversations": conversations.filter {
                    !state.blockedUserIds.contains($0["userId"] as? Int ?? 0)
                },
            ])

        case ("GET", "api/v1/instant/streaks"):
            return try encode([
                "streaks": [[
                    "userId": 2, "name": "Ana", "themeKey": "rose",
                    "profilePictureUrl": NSNull(), "count": 9,
                    "deadline": StubBackend.expiresAt, "atRisk": true,
                ]],
            ])

        case ("GET", "api/v1/instant/\(StubBackend.instantId)/media"):
            guard !state.mediaFetched, let sealed = state.sealed else {
                throw APIError(status: 410, message: "This instant is no longer available.")
            }
            // Destructive, exactly like the real endpoint: a second fetch 410s.
            state.mediaFetched = true
            return sealed.ciphertext

        case ("POST", "api/v1/instant"):
            if case .multipart(let parts) = request.body,
               let media = parts.first(where: { $0.name == "media" }) {
                state.sentInstants.append(media.data)
            }
            return try encode([
                "instant": [
                    "id": UUID().uuidString, "createdAt": StubBackend.timestamp(offsetBySeconds: 0),
                    "expiresAt": StubBackend.expiresAt, "delivered": true,
                ],
            ])

        default:
            if request.method == "DELETE", path.hasPrefix("api/v1/moderation/blocks/"),
               let id = Int(path.dropFirst("api/v1/moderation/blocks/".count)) {
                state.blockedUserIds.removeAll { $0 == id }
                return try encode(["ok": true])
            }
            if path.hasPrefix("api/v1/instant/keys/") {
                return try JSONEncoder().encode(
                    InstantKeysResponse(userId: 2, devices: state.deviceKeys, myDevices: state.deviceKeys)
                )
            }
            if path.hasSuffix("/viewed") {
                return try encode(["ok": true, "viewedAt": StubBackend.timestamp(offsetBySeconds: 0)])
            }
            return try encode(["ok": true])
        }
    }

    /// Seals a real photo to the app's own freshly enrolled device key, so the
    /// viewer under test runs the production decrypt path rather than a bypass.
    private func sealPendingInstant(for device: InstantDeviceKeyDTO, state: inout State) throws {
        guard state.sealed == nil else { return }
        let media = try WebPEncoder.encode(StubBackend.photo(), quality: 0.8)
        let result = try InstantCrypto.seal(
            media: media,
            senderUserId: StubBackend.senderId,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: device.id, deviceId: device.deviceId, publicKey: device.publicKey
            )]
        )
        state.sealed = (
            result.ciphertext,
            InstantDelivery(
                id: StubBackend.instantId,
                senderId: StubBackend.senderId,
                senderName: "Ana",
                senderThemeKey: "rose",
                senderProfilePictureUrl: nil,
                mediaType: "image/webp",
                mediaIv: result.mediaIv,
                ephemeralPubKey: result.ephemeralPubKey,
                byteSize: result.ciphertext.count,
                durationMode: .fiveSeconds,
                createdAt: StubBackend.receivedAt,
                expiresAt: StubBackend.expiresAt,
                envelope: InstantKeyEnvelope(
                    wrappedKey: result.envelopes[0].wrappedKey,
                    wrapIv: result.envelopes[0].wrapIv
                )
            )
        )
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

extension APIRequest {
    var jsonBody: [String: Any]? {
        guard case .json(let data) = body else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
#endif

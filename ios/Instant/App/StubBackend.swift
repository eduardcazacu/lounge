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

    static func timestamp(offsetBySeconds offset: TimeInterval) -> String {
        iso.string(from: Date().addingTimeInterval(offset))
    }

    /// An hour ago, so a contact seeded at "now" is unambiguously more recent.
    static var receivedAt: String { timestamp(offsetBySeconds: -3600) }
    static var expiresAt: String { timestamp(offsetBySeconds: 23 * 3600) }

    static let senderId = 2
    /// Last in the server's ordering, so a picker that respects recency has to
    /// visibly move them to the top.
    static let recentPeerId = 3
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var sentInstants: [Data] { state.withLock { $0.sentInstants } }

    func data(for request: APIRequest) async throws -> Data {
        try state.withLock { try respond(to: request, state: &$0) }
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
                ],
            ])

        case ("GET", "api/v1/user/list"):
            return try encode([
                "users": [
                    ["id": 1, "name": "Tester", "themeKey": "ocean", "profilePictureUrl": NSNull()],
                    ["id": 2, "name": "Ana", "themeKey": "rose", "profilePictureUrl": NSNull()],
                    ["id": 3, "name": "Bo", "themeKey": "forest", "profilePictureUrl": NSNull()],
                ],
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

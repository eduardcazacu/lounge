import Foundation

public protocol InstantAPIProtocol: Sendable {
    func registerDevice(deviceId: String, publicKey: String) async throws -> InstantDeviceKeyDTO
    func keys(forUserId userId: Int) async throws -> (theirs: [InstantDeviceKeyDTO], mine: [InstantDeviceKeyDTO])
    func socketTicket(deviceId: String) async throws -> String
    func inbox(deviceId: String) async throws -> [InstantDelivery]
    func streaks() async throws -> [InstantStreakSummary]
    func send(
        ciphertext: Data,
        recipientId: Int,
        durationMode: InstantDurationMode,
        mediaType: String,
        mediaIv: String,
        ephemeralPubKey: String,
        envelopes: [InstantCrypto.SealedEnvelope]
    ) async throws -> Bool
    func media(instantId: String) async throws -> Data
    func markViewed(instantId: String) async throws
    func markUndecryptable(instantId: String) async throws
}

public struct InstantAPI: InstantAPIProtocol {
    let client: APIClientProtocol
    static let base = "api/v1/instant"

    public init(client: APIClientProtocol) {
        self.client = client
    }

    private struct RegisterDeviceBody: Encodable {
        let deviceId: String
        let publicKey: String
    }

    public func registerDevice(deviceId: String, publicKey: String) async throws -> InstantDeviceKeyDTO {
        try await client.decode(
            DeviceResponse.self,
            from: .post(
                "\(Self.base)/keys",
                json: RegisterDeviceBody(deviceId: deviceId, publicKey: publicKey)
            )
        ).device
    }

    public func keys(
        forUserId userId: Int
    ) async throws -> (theirs: [InstantDeviceKeyDTO], mine: [InstantDeviceKeyDTO]) {
        let response = try await client.decode(
            InstantKeysResponse.self,
            from: .get("\(Self.base)/keys/\(userId)")
        )
        return (response.devices, response.myDevices)
    }

    private struct TicketBody: Encodable { let deviceId: String }

    public func socketTicket(deviceId: String) async throws -> String {
        try await client.decode(
            WSTicketResponse.self,
            from: .post("\(Self.base)/ws-ticket", json: TicketBody(deviceId: deviceId))
        ).ticket
    }

    public func inbox(deviceId: String) async throws -> [InstantDelivery] {
        try await client.decode(
            InboxResponse.self,
            from: .get("\(Self.base)/inbox", query: [URLQueryItem(name: "deviceId", value: deviceId)])
        ).instants
    }

    public func streaks() async throws -> [InstantStreakSummary] {
        try await client.decode(StreaksResponse.self, from: .get("\(Self.base)/streaks")).streaks
    }

    /// The payload travels as a JSON *string* in a form field, not as JSON body —
    /// the ciphertext is the other part of the same multipart request.
    struct CreatePayload: Encodable {
        struct Envelope: Encodable {
            let deviceKeyId: Int
            let wrappedKey: String
            let wrapIv: String
        }
        let recipientId: Int
        let durationMode: InstantDurationMode
        let mediaType: String
        let mediaIv: String
        let ephemeralPubKey: String
        let envelopes: [Envelope]
    }

    /// Returns whether the server reached a live socket. `false` means it fell
    /// back to a push and the recipient will drain it from the inbox later.
    public func send(
        ciphertext: Data,
        recipientId: Int,
        durationMode: InstantDurationMode,
        mediaType: String,
        mediaIv: String,
        ephemeralPubKey: String,
        envelopes: [InstantCrypto.SealedEnvelope]
    ) async throws -> Bool {
        let payload = CreatePayload(
            recipientId: recipientId,
            durationMode: durationMode,
            mediaType: mediaType,
            mediaIv: mediaIv,
            ephemeralPubKey: ephemeralPubKey,
            envelopes: envelopes.map {
                CreatePayload.Envelope(
                    deviceKeyId: $0.deviceKeyId,
                    wrappedKey: $0.wrappedKey,
                    wrapIv: $0.wrapIv
                )
            }
        )
        let encoded = try JSONEncoder().encode(payload)

        let request = APIRequest(
            method: "POST",
            path: Self.base,
            body: .multipart([
                MultipartPart(
                    name: "media",
                    filename: "instant.bin",
                    contentType: "application/octet-stream",
                    data: ciphertext
                ),
                MultipartPart(name: "payload", data: encoded),
            ])
        )
        return try await client.decode(CreateInstantResponse.self, from: request).instant.delivered
    }

    /// Destructive. The server claims the row before it reads R2, so this can
    /// succeed exactly once for a given instant — across every device the
    /// recipient owns. A second call gets 410. Callers must guarantee it fires
    /// once; see `ViewerModel`.
    public func media(instantId: String) async throws -> Data {
        try await client.data(for: .get("\(Self.base)/\(instantId)/media"))
    }

    public func markViewed(instantId: String) async throws {
        _ = try await client.decode(
            ViewedResponse.self,
            from: .post("\(Self.base)/\(instantId)/viewed")
        )
    }

    /// Reports that this device holds no usable envelope, so the server stops
    /// storing ciphertext nobody can ever read.
    public func markUndecryptable(instantId: String) async throws {
        try await client.send(.post("\(Self.base)/\(instantId)/undecryptable"))
    }
}

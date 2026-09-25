import Foundation
import Testing
@testable import Instant

@Suite("API client")
struct APIClientTests {
    private func makeClient(
        stub: Stub,
        tokens: TokenStoring = InMemoryTokenStore(token: "access-token"),
        onExpired: @escaping @Sendable () -> Void = {}
    ) -> APIClient {
        APIClient(
            config: .production,
            tokens: tokens,
            session: stub.session,
            onSessionExpired: onExpired
        )
    }

    @Test("Attaches the bearer token to authenticated calls only")
    func attachesBearer() async throws {
        let stub = Stub(handler: Stub.json("{}"))
        let client = makeClient(stub: stub)

        _ = try await client.data(for: .get("api/v1/instant/streaks"))
        _ = try await client.data(
            for: APIRequest(method: "POST", path: "api/v1/user/signin", authenticated: false)
        )

        let requests = stub.requests
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Decodes the API's error envelope")
    func decodesErrorBody() async throws {
        let stub = Stub(handler: Stub.json(
            #"{"msg":"Invalid instant","errors":{"fieldErrors":{"recipientId":["Required"]}}}"#,
            status: 400
        ))
        let client = makeClient(stub: stub)

        await #expect(throws: APIError.self) {
            _ = try await client.data(for: .get("api/v1/instant/streaks"))
        }

        do {
            _ = try await client.data(for: .get("api/v1/instant/streaks"))
        } catch let error as APIError {
            #expect(error.status == 400)
            #expect(error.message == "Invalid instant")
            #expect(error.fieldErrors["recipientId"] == ["Required"])
        }
    }

    /// The backend answers auth failures with 403 rather than 401, so refresh
    /// has to key off 403 or the session silently dies every 15 minutes.
    @Test("Refreshes once on 403 and retries")
    func refreshesOn403() async throws {
        let tokens = InMemoryTokenStore(token: "stale")
        let calls = Counter()
        let stub = Stub { request in
            if request.path.hasSuffix("/refresh") {
                return .init(status: 200, body: Data(#"{"token":"fresh"}"#.utf8))
            }
            return calls.next() == 0
                ? .init(status: 403, body: Data(#"{"msg":"You are not logged in"}"#.utf8))
                : .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }

        let client = makeClient(stub: stub, tokens: tokens)
        _ = try await client.data(for: .get("api/v1/instant/streaks"))

        #expect(tokens.token == "fresh")
        let paths = stub.requests.map(\.path)
        #expect(paths.filter { $0.hasSuffix("/refresh") }.count == 1)
        // Original, refresh, retry.
        #expect(paths.count == 3)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    /// A JWT whose only claims are the two the client reads.
    private func jwt(expiringAt expiry: Date) -> String {
        let payload = #"{"id":7,"exp":\#(Int(expiry.timeIntervalSince1970))}"#
        return "e30.\(Base64URL.encode(Data(payload.utf8))).sig"
    }

    /// A cold start's token has usually expired. Sending it anyway spends a
    /// round trip on a 403 that says what the expiry already did.
    @Test("An expired token is refreshed before the request, not after its 403")
    func refreshesExpiredTokenFirst() async throws {
        let now = Date()
        let tokens = InMemoryTokenStore(token: jwt(expiringAt: now.addingTimeInterval(-60)))
        let stub = Stub { request in
            request.path.hasSuffix("/refresh")
                ? .init(status: 200, body: Data(#"{"token":"fresh"}"#.utf8))
                : .init(status: 200, body: Data("{}".utf8))
        }
        let client = APIClient(config: .production, tokens: tokens, session: stub.session, now: { now })

        _ = try await client.data(for: .get("api/v1/instant/inbox"))

        let paths = stub.requests.map(\.path)
        #expect(paths.count == 2)
        #expect(paths.first?.hasSuffix("/refresh") == true)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("A token with time left is sent as it is")
    func keepsLiveToken() async throws {
        let now = Date()
        let token = jwt(expiringAt: now.addingTimeInterval(600))
        let stub = Stub(handler: Stub.json("{}"))
        let client = APIClient(
            config: .production, tokens: InMemoryTokenStore(token: token), session: stub.session, now: { now }
        )

        _ = try await client.data(for: .get("api/v1/instant/inbox"))

        #expect(stub.requests.map(\.path) == ["/api/v1/instant/inbox"])
    }

    /// Offline, the early refresh fails; that must not be read as the session
    /// ending. The request still goes, and the 403 path has the final say.
    @Test("A failed early refresh still sends the request")
    func sendsAfterFailedEarlyRefresh() async throws {
        let now = Date()
        let expired = jwt(expiringAt: now.addingTimeInterval(-60))
        let refreshes = Counter()
        let stub = Stub { request in
            if request.path.hasSuffix("/refresh") {
                return refreshes.next() == 0
                    ? .init(status: 503, body: Data("{}".utf8))
                    : .init(status: 200, body: Data(#"{"token":"fresh"}"#.utf8))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? .init(status: 200, body: Data("{}".utf8))
                : .init(status: 403, body: Data(#"{"msg":"You are not logged in"}"#.utf8))
        }
        let expiredCalls = Counter()
        let client = APIClient(
            config: .production, tokens: InMemoryTokenStore(token: expired), session: stub.session,
            now: { now }, onSessionExpired: { _ = expiredCalls.next() }
        )

        _ = try await client.data(for: .get("api/v1/instant/inbox"))

        #expect(expiredCalls.count == 0, "the session was never over")
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("Gives up after one failed refresh instead of looping")
    func stopsAfterFailedRefresh() async throws {
        let expired = Counter()
        let stub = Stub { request in
            request.path.hasSuffix("/refresh")
                ? .init(status: 401, body: Data(#"{"msg":"Invalid refresh token"}"#.utf8))
                : .init(status: 403, body: Data(#"{"msg":"You are not logged in"}"#.utf8))
        }

        let client = makeClient(stub: stub, onExpired: { _ = expired.next() })
        await #expect(throws: APIError.self) {
            _ = try await client.data(for: .get("api/v1/instant/streaks"))
        }
        #expect(expired.count == 1)
        #expect(stub.requests.count == 2)
    }

    /// A sign-in 403 means "wrong password" or "pending approval" — refreshing
    /// would be pointless and would replace a useful message with a generic one.
    @Test("Does not refresh on an unauthenticated call's 403")
    func doesNotRefreshUnauthenticatedCalls() async throws {
        let stub = Stub(handler: Stub.json(#"{"msg":"Incorrect credentials"}"#, status: 403))
        let client = makeClient(stub: stub)

        await #expect(throws: APIError.self) {
            _ = try await client.data(
                for: APIRequest(method: "POST", path: "api/v1/user/signin", authenticated: false)
            )
        }
        #expect(stub.requests.count == 1)
    }

    /// `POST /user/refresh` authenticates from the `refresh_token` cookie alone.
    /// If a signed-out app answered its first 403 by refreshing, it would adopt
    /// whichever account that ambient cookie belongs to and come up signed in as
    /// them — which is exactly what happened on a Simulator, where cookie and
    /// keychain storage are not sandboxed per app. Refresh renews a session; it
    /// must never start one.
    @Test("Never refreshes when there is no session to renew")
    func doesNotRefreshWithoutAToken() async throws {
        let stub = Stub { request in
            request.path.hasSuffix("/refresh")
                ? .init(status: 200, body: Data(#"{"token":"someone-elses"}"#.utf8))
                : .init(status: 403, body: Data(#"{"msg":"You are not logged in"}"#.utf8))
        }
        let tokens = InMemoryTokenStore(token: nil)
        let client = makeClient(stub: stub, tokens: tokens)

        await #expect(throws: APIError.self) {
            _ = try await client.data(for: .get("api/v1/instant/streaks"))
        }

        #expect(tokens.token == nil, "a signed-out app must stay signed out")
        #expect(stub.requests.allSatisfy { !$0.path.hasSuffix("/refresh") })
        #expect(stub.requests.count == 1)
    }

    @Test("Concurrent 403s trigger exactly one refresh")
    func coalescesConcurrentRefreshes() async throws {
        let seen = Counter()
        let stub = Stub { request in
            if request.path.hasSuffix("/refresh") {
                return .init(status: 200, body: Data(#"{"token":"fresh"}"#.utf8))
            }
            return seen.next() < 4
                ? .init(status: 403, body: Data(#"{"msg":"nope"}"#.utf8))
                : .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }

        let client = makeClient(stub: stub, tokens: InMemoryTokenStore(token: "stale"))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try? await client.data(for: .get("api/v1/instant/streaks")) }
            }
        }

        let refreshes = stub.requests.filter { $0.path.hasSuffix("/refresh") }
        #expect(refreshes.count == 1)
    }

    @Test("Builds multipart bodies the backend can parse")
    func buildsMultipart() {
        let body = APIClient.multipartBody(
            parts: [
                MultipartPart(
                    name: "media", filename: "instant.bin",
                    contentType: "application/octet-stream", data: Data([0xDE, 0xAD])
                ),
                MultipartPart(name: "payload", data: Data(#"{"a":1}"#.utf8)),
            ],
            boundary: "BOUND"
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--BOUND\r\n"))
        #expect(text.contains(#"Content-Disposition: form-data; name="media"; filename="instant.bin""#))
        #expect(text.contains("Content-Type: application/octet-stream"))
        #expect(text.contains(#"Content-Disposition: form-data; name="payload""#))
        #expect(text.hasSuffix("--BOUND--\r\n"))
        // The payload part carries no Content-Type: it is a plain form field
        // holding a JSON string, which is what the handler reads.
        #expect(text.components(separatedBy: "Content-Type:").count == 2)
    }

    @Test("Keeps cookies so the refresh token survives")
    func sessionKeepsCookies() {
        let session = APIClient.makeSession()
        #expect(session.configuration.httpShouldSetCookies)
        #expect(session.configuration.httpCookieAcceptPolicy == .always)
    }

    @Test("Derives the socket origin from the API origin")
    func derivesWebSocketURL() {
        #expect(
            AppConfig.production.webSocketBaseURL.absoluteString
                == "wss://api.lounge.eduardcazacu.com"
        )
        #expect(AppConfig.localWorker.webSocketBaseURL.absoluteString == "ws://localhost:8787")
    }
}

/// Thread-safe call counter for the stub handlers, which run off the test actor.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }

    var count: Int { lock.withLock { value } }
}

@Suite("Instant endpoints")
struct InstantAPITests {
    private func makeAPI(_ stub: Stub) -> InstantAPI {
        InstantAPI(client: APIClient(
            config: .production,
            tokens: InMemoryTokenStore(token: "t"),
            session: stub.session
        ))
    }

    @Test("Device registration posts the id and public key")
    func registersDevice() async throws {
        let stub = Stub(handler: Stub.json(#"{"device":{"id":3,"deviceId":"abc","publicKey":"pk","createdAt":"2026-01-01T00:00:00.000Z"}}"#, status: 200))
        let device = try await makeAPI(stub).registerDevice(deviceId: "abc", publicKey: "pk")

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/api/v1/instant/keys")
        #expect(request.bodyJSON["deviceId"] as? String == "abc")
        #expect(request.bodyJSON["publicKey"] as? String == "pk")
        #expect(device.id == 3)
    }

    @Test("The key directory returns both sides")
    func readsKeyDirectory() async throws {
        let stub = Stub(handler: Stub.json(#"{"userId":7,"devices":[{"id":1,"deviceId":"d1","publicKey":"p1","createdAt":null}],"myDevices":[{"id":2,"deviceId":"d2","publicKey":"p2","createdAt":null}]}"#, status: 200))
        let keys = try await makeAPI(stub).keys(forUserId: 7)
        #expect(stub.requests.first?.path == "/api/v1/instant/keys/7")
        #expect(keys.theirs.map(\.deviceId) == ["d1"])
        #expect(keys.mine.map(\.deviceId) == ["d2"])
    }

    @Test("Inbox passes deviceId as a query parameter")
    func drainsInbox() async throws {
        let stub = Stub(handler: Stub.json(#"{"instants":[]}"#, status: 200))
        _ = try await makeAPI(stub).inbox(deviceId: "device-42")

        let request = try #require(stub.requests.first)
        #expect(request.path == "/api/v1/instant/inbox")
        #expect(request.queryItems["deviceId"] == "device-42")
    }

    @Test("Send posts exactly two multipart fields")
    func sendsMultipart() async throws {
        let stub = Stub(handler: Stub.json(#"{"instant":{"id":"i1","createdAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z","delivered":false}}"#, status: 200))

        let delivered = try await makeAPI(stub).send(
            ciphertext: Data([1, 2, 3]),
            recipientId: 9,
            durationMode: .oneSecond,
            mediaType: "image/webp",
            mediaIv: "iv",
            ephemeralPubKey: "epk",
            envelopes: [InstantCrypto.SealedEnvelope(deviceKeyId: 4, wrappedKey: "wk", wrapIv: "wiv")]
        )

        #expect(delivered == false)
        let request = try #require(stub.requests.first)
        #expect(request.path == "/api/v1/instant")
        let body = request.bodyText
        #expect(body.contains(#"name="media"; filename="instant.bin""#))
        #expect(body.contains(#"name="payload""#))
        #expect(body.contains(#""recipientId":9"#))
        #expect(body.contains(#""durationMode":"1s""#))
        #expect(body.contains(#""deviceKeyId":4"#))
    }

    @Test("A spent instant surfaces as gone, not as a generic failure")
    func mapsGoneStatus() async throws {
        let stub = Stub(handler: Stub.json(
            #"{"msg":"This instant is no longer available."}"#,
            status: 410
        ))
        do {
            _ = try await makeAPI(stub).media(instantId: "i1")
            Issue.record("expected a 410")
        } catch let error as APIError {
            #expect(error.isGone)
        }
    }

    @Test("Realtime-unsupported is distinguishable from an outage")
    func detects501() async throws {
        let stub = Stub(handler: Stub.json(
            #"{"msg":"Realtime Instant delivery needs the INSTANT_INBOX Durable Object binding."}"#,
            status: 501
        ))
        do {
            _ = try await makeAPI(stub).socketTicket(deviceId: "d")
            Issue.record("expected a 501")
        } catch let error as APIError {
            #expect(error.isRealtimeUnsupported)
        }
    }

    /// The receipt for the last photo sent the other way, which is the only
    /// part of a conversation that is about the caller rather than the partner.
    @Test("Conversations carry the receipt for what was sent to them")
    func decodesSendReceipts() async throws {
        let stub = Stub(handler: Stub.json(#"""
        {"conversations":[
          {"userId":2,"name":"Ana","themeKey":"rose","profilePictureUrl":null,
           "lastInteractionAt":"2026-01-01T00:00:00.000Z","lastSentAt":"2026-01-01T00:00:00.000Z",
           "lastReceivedAt":null,"unopenedCount":0,
           "lastSentReceipt":{"sentAt":"2026-01-01T00:00:00.000Z",
             "openedAt":"2026-01-01T00:05:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z"},
           "streakCount":0,"streakDeadline":null,"streakAtRisk":false},
          {"userId":3,"name":"Bo","themeKey":"forest","profilePictureUrl":null,
           "lastInteractionAt":"2026-01-01T00:00:00.000Z","lastSentAt":null,
           "lastReceivedAt":"2026-01-01T00:00:00.000Z","unopenedCount":0,
           "streakCount":0,"streakDeadline":null,"streakAtRisk":false}
        ]}
        """#, status: 200))

        let conversations = try await makeAPI(stub).conversations()

        #expect(stub.requests.first?.path == "/api/v1/instant/conversations")
        #expect(conversations[0].lastSentReceipt?.openedAt == "2026-01-01T00:05:00.000Z")
        // Bo's entry leaves the key out altogether, which is what an inbox
        // cached by a build older than receipts looks like. It decodes as
        // nothing rather than failing the whole list and losing the cache.
        #expect(conversations[1].lastSentReceipt == nil)
    }

    @Test("Receipt and undecryptable hit the right paths")
    func postsLifecycleEndpoints() async throws {
        let stub = Stub(handler: Stub.json(
            #"{"ok":true,"viewedAt":"2026-01-01T00:00:00.000Z"}"#,
            status: 200
        ))
        let api = makeAPI(stub)
        try await api.markViewed(instantId: "abc")
        try await api.markUndecryptable(instantId: "abc")

        let paths = stub.requests.map(\.path)
        #expect(paths == ["/api/v1/instant/abc/viewed", "/api/v1/instant/abc/undecryptable"])
        #expect(stub.requests.allSatisfy { $0.httpMethod == "POST" })
    }
}

@Suite("User endpoints")
struct UserAPITests {
    private func makeAPI(_ stub: Stub) -> UserAPI {
        UserAPI(client: APIClient(
            config: .production,
            tokens: InMemoryTokenStore(token: "t"),
            session: stub.session
        ))
    }

    @Test("Sign-in posts credentials without a bearer header")
    func signsIn() async throws {
        let stub = Stub(handler: Stub.json(#"{"token":"jwt"}"#, status: 200))

        let token = try await makeAPI(stub).signIn(email: "a@b.c", password: "pw")
        #expect(token == "jwt")

        let request = try #require(stub.requests.first)
        #expect(request.path == "/api/v1/user/signin")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.bodyJSON["email"] as? String == "a@b.c")
        #expect(request.bodyJSON["password"] as? String == "pw")
    }

    @Test("The three sign-in rejections come through verbatim")
    func surfacesDistinctRejections() async throws {
        for message in [
            "Incorrect credentials",
            "Please verify your email before signing in.",
            "Your account is pending admin approval.",
        ] {
            let stub = Stub(handler: Stub.json(#"{"msg":"\#(message)"}"#, status: 403))
            do {
                _ = try await makeAPI(stub).signIn(email: "a@b.c", password: "pw")
                Issue.record("expected a rejection")
            } catch let error as APIError {
                #expect(error.message == message)
            }
        }
    }

    /// The handler coerces a missing `bio` to "" and writes it, so omitting the
    /// field to mean "unchanged" wipes it.
    @Test("Profile updates always send bio")
    func alwaysSendsBio() async throws {
        let stub = Stub(handler: Stub.json(#"{"user":{"id":1,"name":"Ana","bio":"kept","themeKey":"rose","profilePictureKey":null,"profilePictureUrl":null}}"#, status: 200))
        _ = try await makeAPI(stub).updateProfile(bio: "kept", themeKey: "rose")

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.bodyJSON["bio"] as? String == "kept")
        #expect(request.bodyJSON["themeKey"] as? String == "rose")
    }

    @Test("Notifications endpoint returns the flat shape")
    func togglesNotifications() async throws {
        let stub = Stub(handler: Stub.json(
            #"{"notificationsEnabled":false}"#,
            status: 200
        ))
        #expect(try await makeAPI(stub).setNotificationsEnabled(false) == false)
        #expect(stub.requests.first?.path == "/api/v1/user/me/notifications")
    }

    /// The token itself is the endpoint; `provider` is what tells the backend
    /// which push service — and which APNs environment — it belongs to.
    @Test("APNs registration distinguishes sandbox from production")
    func registersAPNsToken() async throws {
        for sandbox in [true, false] {
            let stub = Stub(handler: Stub.json(#"{"msg":"Push subscription stored."}"#, status: 200))
            try await makeAPI(stub).registerAPNsToken("deadbeef", sandbox: sandbox)

            let request = try #require(stub.requests.first)
            #expect(request.path == "/api/v1/user/me/push/subscribe")
            #expect(request.bodyJSON["endpoint"] as? String == "deadbeef")
            #expect(request.bodyJSON["provider"] as? String == (sandbox ? "apns-sandbox" : "apns"))
            #expect(request.bodyJSON["keys"] == nil)
        }
    }

    @Test("The user list decodes nullable names and pictures")
    func listsUsers() async throws {
        let stub = Stub(handler: Stub.json(#"{"users":[{"id":1,"name":null,"themeKey":"gold","profilePictureUrl":null}]}"#, status: 200))
        let users = try await makeAPI(stub).users()
        #expect(users.first?.name == nil)
        #expect(users.first?.displayName == "Someone")
    }
}

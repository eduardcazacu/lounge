import Foundation
import Testing
@testable import Instant

@Suite("Wire format")
struct WireFormatTests {
    @Test("Decodes a delivery with every field populated")
    func decodesDelivery() throws {
        let json = """
        {"id":"i1","senderId":2,"senderName":"Ana","senderThemeKey":"rose",
         "senderProfilePictureUrl":"https://x/y.webp","mediaType":"image/webp",
         "mediaIv":"iv","ephemeralPubKey":"epk","byteSize":1234,"durationMode":"infinite",
         "createdAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z",
         "envelope":{"wrappedKey":"wk","wrapIv":"wiv"}}
        """
        let instant = try JSONDecoder().decode(InstantDelivery.self, from: Data(json.utf8))
        #expect(instant.durationMode == .infinite)
        #expect(instant.envelope?.wrappedKey == "wk")
        #expect(instant.byteSize == 1234)
    }

    /// A null envelope is the key-loss path: the identity was replaced after the
    /// sender wrapped, so nothing on this device can open it.
    @Test("A null envelope decodes rather than failing")
    func decodesNullEnvelope() throws {
        let json = """
        {"id":"i1","senderId":2,"senderName":null,"senderThemeKey":"rose",
         "senderProfilePictureUrl":null,"mediaType":"image/webp","mediaIv":"",
         "ephemeralPubKey":"","byteSize":0,"durationMode":"1s",
         "createdAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z",
         "envelope":null}
        """
        let instant = try JSONDecoder().decode(InstantDelivery.self, from: Data(json.utf8))
        #expect(instant.envelope == nil)
        #expect(instant.displayName == "Someone")
        // Scrubbed rows send empty strings, not nulls, for these.
        #expect(instant.mediaIv.isEmpty)
    }

    @Test("Decodes each server frame")
    func decodesWireEvents() {
        #expect(
            InstantWireEvent.decode(from: Data(#"{"type":"ready","deviceId":"d1"}"#.utf8))
                == .ready(deviceId: "d1")
        )
        #expect(
            InstantWireEvent.decode(
                from: Data(#"{"type":"opened","instantId":"i1","recipientId":5,"openedAt":"2026-01-01T00:00:00.000Z"}"#.utf8)
            ) == .opened(instantId: "i1", recipientId: 5, openedAt: "2026-01-01T00:00:00.000Z")
        )
        guard case .instant? = InstantWireEvent.decode(from: Data("""
        {"type":"instant","instant":{"id":"i1","senderId":2,"senderName":"Ana",
         "senderThemeKey":"rose","senderProfilePictureUrl":null,"mediaType":"image/webp",
         "mediaIv":"iv","ephemeralPubKey":"epk","byteSize":1,"durationMode":"5s",
         "createdAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z",
         "envelope":{"wrappedKey":"wk","wrapIv":"wiv"}}}
        """.utf8)) else {
            Issue.record("expected an instant frame")
            return
        }
    }

    @Test("Unknown and non-JSON frames are ignored, not fatal")
    func ignoresUnknownFrames() {
        #expect(InstantWireEvent.decode(from: Data("pong".utf8)) == nil)
        #expect(InstantWireEvent.decode(from: Data(#"{"type":"whatever"}"#.utf8)) == nil)
        #expect(InstantWireEvent.decode(from: Data()) == nil)
    }

    /// The keepalive is a literal text frame answered by the Durable Object's
    /// auto-response with the bare string "pong" — not JSON, and not a
    /// protocol-level ping.
    @Test("pong is filtered before decoding")
    func filtersPong() {
        #expect(InboxSocket.event(from: .string("pong")) == nil)
        #expect(InboxSocket.event(from: .string("ready")) == nil)
        #expect(
            InboxSocket.event(from: .string(#"{"type":"ready","deviceId":"x"}"#))
                == .ready(deviceId: "x")
        )
        #expect(InboxSocket.pingFrame == "ping")
    }

    @Test("Duration modes map to the web client's timings")
    func durationMapping() {
        #expect(InstantDurationMode.oneSecond.duration == .seconds(1))
        #expect(InstantDurationMode.fiveSeconds.duration == .seconds(5))
        #expect(InstantDurationMode.infinite.duration == nil)
        #expect(InstantDurationMode.oneSecond.next == .fiveSeconds)
        #expect(InstantDurationMode.fiveSeconds.next == .infinite)
        #expect(InstantDurationMode.infinite.next == .oneSecond)
    }

    @Test("Streak summaries decode with nullable fields")
    func decodesStreaks() throws {
        let json = """
        {"streaks":[{"userId":7,"name":null,"themeKey":"ocean","profilePictureUrl":null,
          "count":12,"deadline":null,"atRisk":true}]}
        """
        let response = try JSONDecoder().decode(StreaksResponse.self, from: Data(json.utf8))
        #expect(response.streaks.first?.count == 12)
        #expect(response.streaks.first?.deadline == nil)
        #expect(response.streaks.first?.atRisk == true)
    }
}

@Suite("Reconnect backoff")
struct BackoffTests {
    @Test("Doubles from one second and stops at thirty")
    func schedule() {
        var backoff = ReconnectBackoff()
        let delays = (0..<8).map { _ in backoff.next() }
        #expect(delays == [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8),
            .seconds(16), .seconds(30), .seconds(30), .seconds(30),
        ])
    }

    @Test("A successful connection resets it")
    func resets() {
        var backoff = ReconnectBackoff()
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }
}

@Suite("Connection warnings")
struct ConnectionWarningTests {
    /// The happy path and the two momentary startup states say nothing. An
    /// indicator that is always on screen is noise, and a coloured dot with no
    /// text reads as a warning even when everything is fine.
    @Test("Says nothing when there is nothing wrong")
    func silentWhenHealthy() {
        #expect(InstantConnectionState.open.warningText == nil)
        #expect(InstantConnectionState.connecting.warningText == nil)
        #expect(InstantConnectionState.idle.warningText == nil)
    }

    @Test("Speaks up when delivery is actually broken")
    func warnsWhenBroken() {
        #expect(InstantConnectionState.offline.warningText == "Reconnecting")
        #expect(InstantConnectionState.unsupported.warningText == "Live updates off")
    }

    /// Reconnecting fixes itself and deserves an attention colour; a backend
    /// with no Durable Object never will, so it stays muted.
    @Test("Distinguishes a blip from a dead end")
    func separatesRecoverableFromTerminal() {
        #expect(InstantConnectionState.offline.isRecoverable)
        #expect(InstantConnectionState.unsupported.isRecoverable == false)
    }
}

@Suite("Session store")
struct SessionStoreTests {
    private func token(id: Int, exp: Double = 4_102_444_800) -> String {
        let header = Base64URL.encode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = Base64URL.encode(Data(#"{"id":\#(id),"exp":\#(Int(exp))}"#.utf8))
        return "\(header).\(payload).sig"
    }

    /// Read without verifying, exactly as the web client does. It only keys
    /// local state and the HKDF info string; every real authorization decision
    /// happens server-side against the signature.
    @Test("Reads the id claim out of the token")
    func readsIdClaim() {
        #expect(SessionStore.userId(fromJWT: token(id: 42)) == 42)
        #expect(SessionStore.userId(fromJWT: "not.a.jwt") == nil)
        #expect(SessionStore.userId(fromJWT: "onlyonepart") == nil)
    }

    @Test("Reads the expiry")
    func readsExpiry() {
        let expiry = SessionStore.expiry(ofJWT: token(id: 1, exp: 1_700_000_000))
        #expect(expiry == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// `isSignedIn` keyed off "the keychain held something" would strand the app
    /// on a camera screen it can never load anything into, with no route back to
    /// sign-in short of deleting it.
    @Test("An unreadable stored token is discarded, not treated as a session")
    func rejectsUnparseableToken() {
        let keychain = InMemoryKeychain(seed: ["session:access-token": Data("garbage".utf8)])
        let store = SessionStore(keychain: keychain)

        #expect(store.isSignedIn == false)
        #expect(store.currentUserId == nil)
        #expect(keychain.read(account: "session:access-token") == nil, "and it is cleaned up")
    }

    @Test("Persists and clears through the keychain")
    func persists() {
        let keychain = InMemoryKeychain()
        let store = SessionStore(keychain: keychain)
        store.setToken(token(id: 5))
        #expect(keychain.read(account: "session:access-token") != nil)

        let reloaded = SessionStore(keychain: keychain)
        #expect(reloaded.currentUserId == 5)
        #expect(reloaded.isSignedIn)

        reloaded.signOut()
        #expect(keychain.read(account: "session:access-token") == nil)
    }
}

@Suite("Recent contacts")
struct RecentContactsTests {
    @Test("Remembers per account and peer pair")
    func keyedByBothSides() {
        let store = InMemoryRecentContactsStore()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(peerUserId: 2, for: 1, at: when)

        #expect(store.lastInteraction(with: 2, for: 1) == when)
        #expect(store.lastInteraction(with: 2, for: 3) == nil, "another account has its own history")
        #expect(store.lastInteraction(with: 1, for: 2) == nil, "and the pair is directional")
    }

    /// Draining a backlog can deliver older instants after newer ones, so the
    /// mark only ever moves forwards — otherwise a week-old photo arriving late
    /// would drag someone back down the list.
    @Test("Only ever moves forwards")
    func neverGoesBackwards() {
        let store = InMemoryRecentContactsStore()
        let recent = Date(timeIntervalSince1970: 2_000_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000_000)

        store.record(peerUserId: 2, for: 1, at: recent)
        store.record(peerUserId: 2, for: 1, at: older)
        #expect(store.lastInteraction(with: 2, for: 1) == recent)

        let newest = Date(timeIntervalSince1970: 3_000_000_000)
        store.record(peerUserId: 2, for: 1, at: newest)
        #expect(store.lastInteraction(with: 2, for: 1) == newest)
    }

    @Test("Nothing recorded reads as nothing")
    func emptyByDefault() {
        #expect(InMemoryRecentContactsStore().lastInteraction(with: 2, for: 1) == nil)
    }
}

@Suite("Wire timestamps")
struct InstantTimestampTests {
    /// The backend serializes with fractional seconds; the fallback covers a
    /// timestamp written without them.
    @Test("Parses both shapes the API emits")
    func parsesBothFormats() {
        #expect(
            InstantTimestamp.parse("2026-01-01T00:00:00.000Z")
                == Date(timeIntervalSince1970: 1_767_225_600)
        )
        #expect(
            InstantTimestamp.parse("2026-01-01T00:00:00Z")
                == Date(timeIntervalSince1970: 1_767_225_600)
        )
    }

    @Test("Nonsense parses to nothing rather than to 1970")
    func rejectsGarbage() {
        #expect(InstantTimestamp.parse("") == nil)
        #expect(InstantTimestamp.parse("yesterday") == nil)
    }
}

@Suite("Peer fingerprints")
struct PeerFingerprintTests {
    @Test("Remembers per account and peer pair")
    func keyedByBothSides() {
        let store = InMemoryPeerFingerprintStore()
        store.remember("abc", userId: 1, peerUserId: 2)

        #expect(store.fingerprint(userId: 1, peerUserId: 2) == "abc")
        // The same peer seen from another account is a separate trust decision.
        #expect(store.fingerprint(userId: 3, peerUserId: 2) == nil)
        #expect(store.fingerprint(userId: 2, peerUserId: 1) == nil)
    }
}

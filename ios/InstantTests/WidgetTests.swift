import Foundation
import Testing
@testable import Instant

/// Points the shared store at a temp directory, since a test process has no
/// App Group container of its own.
final class TemporaryContainer {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("widget-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        InstantWidgetStore.containerOverride = url
    }

    deinit {
        InstantWidgetStore.containerOverride = nil
        try? FileManager.default.removeItem(at: url)
    }
}

final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

extension InstantWidgetSnapshot.Contact {
    static func fixture(
        userId: Int,
        name: String = "Ana",
        themeKey: String = "rose",
        profilePictureUrl: String? = nil,
        avatarFile: String? = nil,
        unopenedCount: Int = 1,
        streakCount: Int = 0
    ) -> InstantWidgetSnapshot.Contact {
        InstantWidgetSnapshot.Contact(
            userId: userId, name: name, themeKey: themeKey,
            profilePictureUrl: profilePictureUrl, avatarFile: avatarFile,
            unopenedCount: unopenedCount, streakCount: streakCount
        )
    }
}

/// Serialized: `containerOverride` is process-global, so two of these running
/// at once would point the store at each other's directory.
@Suite("Widget snapshot store", .serialized)
struct WidgetStoreTests {
    @Test("Round-trips through the shared container")
    func roundTrips() throws {
        let container = TemporaryContainer()
        defer { _ = container }

        let snapshot = InstantWidgetSnapshot(
            contacts: [.fixture(userId: 2, streakCount: 9)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try InstantWidgetStore.save(snapshot)

        #expect(InstantWidgetStore.load() == snapshot)
    }

    /// The widget must render *something* rather than crash when the app has
    /// never run, or when the container is unreachable.
    @Test("An absent snapshot reads as empty")
    func missingReadsEmpty() {
        let container = TemporaryContainer()
        defer { _ = container }
        #expect(InstantWidgetStore.load() == .empty)
        #expect(InstantWidgetStore.load().isEmpty)
    }

    @Test("Corrupt data reads as empty rather than throwing")
    func corruptReadsEmpty() throws {
        let container = TemporaryContainer()
        defer { _ = container }
        try Data("not json".utf8).write(
            to: container.url.appendingPathComponent(InstantWidgetStore.snapshotName)
        )
        #expect(InstantWidgetStore.load() == .empty)
    }

    @Test("Caches an avatar and hands back its filename")
    func writesAvatar() throws {
        let container = TemporaryContainer()
        defer { _ = container }

        let file = try #require(InstantWidgetStore.writeAvatar(Data([1, 2, 3]), for: 7))
        let url = try #require(InstantWidgetStore.avatarURL(named: file))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    /// Otherwise the container grows every time someone new sends an instant.
    @Test("Prunes pictures for people no longer waiting")
    func prunesAvatars() throws {
        let container = TemporaryContainer()
        defer { _ = container }

        InstantWidgetStore.writeAvatar(Data([1]), for: 1)
        InstantWidgetStore.writeAvatar(Data([2]), for: 2)
        InstantWidgetStore.pruneAvatars(keeping: [2])

        #expect(InstantWidgetStore.avatarURL(named: "1.img").map { FileManager.default.fileExists(atPath: $0.path) } == false)
        #expect(InstantWidgetStore.avatarURL(named: "2.img").map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    /// A reload spent on nothing is one the Notification Service Extension
    /// cannot have when an instant arrives.
    @Test("Publishing what the widget already shows does not reload it")
    func skipsUnchangedSnapshot() async throws {
        let container = TemporaryContainer()
        defer { _ = container }
        let reloads = ReloadCounter()
        let publisher = WidgetSnapshotPublisher(reload: { reloads.increment() })
        let contacts: [InstantWidgetSnapshot.Contact] = [.fixture(userId: 1), .fixture(userId: 2)]

        await publisher.publish(InstantWidgetSnapshot(contacts: contacts, updatedAt: .distantPast))
        await publisher.publish(InstantWidgetSnapshot(contacts: contacts, updatedAt: .now))
        #expect(reloads.count == 1, "a newer timestamp alone is not a change")

        await publisher.publish(InstantWidgetSnapshot(
            contacts: [.fixture(userId: 1, unopenedCount: 2), .fixture(userId: 2)],
            updatedAt: .now
        ))
        #expect(reloads.count == 2)
        #expect(InstantWidgetStore.load().contacts.first?.unopenedCount == 2)
    }

    /// The extension writes the snapshot too, so the app must not reload for a
    /// change the extension has already drawn.
    @Test("An arrival the extension already wrote is not published again")
    func skipsWhatTheExtensionWrote() async throws {
        let container = TemporaryContainer()
        defer { _ = container }
        try InstantWidgetStore.save(InstantWidgetSnapshot.empty.addingArrival(
            senderId: 3, name: "Ana", themeKey: "rose", profilePictureUrl: nil, now: .now
        ))
        let reloads = ReloadCounter()
        let publisher = WidgetSnapshotPublisher(reload: { reloads.increment() })

        await publisher.publish(InstantWidgetSnapshot(contacts: [.fixture(userId: 3)], updatedAt: .now))
        #expect(reloads.count == 0)
    }

    @Test("Clearing empties both the snapshot and the pictures")
    func clears() {
        let container = TemporaryContainer()
        defer { _ = container }

        InstantWidgetStore.writeAvatar(Data([1]), for: 1)
        try? InstantWidgetStore.save(
            InstantWidgetSnapshot(contacts: [.fixture(userId: 1)], updatedAt: .now)
        )
        InstantWidgetStore.clear()

        #expect(InstantWidgetStore.load().isEmpty)
        #expect(InstantWidgetStore.avatarURL(named: "1.img").map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test("Initials match the app's avatar rule")
    func initials() {
        #expect(InstantWidgetSnapshot.Contact.fixture(userId: 1, name: "Ana Lovelace").initials == "AL")
        #expect(InstantWidgetSnapshot.Contact.fixture(userId: 1, name: "Bo").initials == "B")
        #expect(InstantWidgetSnapshot.Contact.fixture(userId: 1, name: "").initials == "?")
    }

    @Test("Totals across everyone waiting")
    func totals() {
        let snapshot = InstantWidgetSnapshot(
            contacts: [
                .fixture(userId: 1, unopenedCount: 2),
                .fixture(userId: 2, unopenedCount: 3),
            ],
            updatedAt: .now
        )
        #expect(snapshot.totalWaiting == 5)
    }
}

/// The Notification Service Extension's only job: keep the widget honest while
/// the app is closed. It has no token and cannot call the API, so everything it
/// knows comes from the push payload.
@Suite("Skipping unchanged widget snapshots")
struct WidgetUnchangedTests {
    private func snapshot(_ contacts: [InstantWidgetSnapshot.Contact]) -> InstantWidgetSnapshot {
        InstantWidgetSnapshot(contacts: contacts, updatedAt: .now)
    }

    @Test("A cached picture on disk still counts as showing")
    func ignoresAvatarFile() {
        let url = "https://example.com/a.png"
        #expect(WidgetSnapshotPublisher.isAlreadyShowing(
            snapshot([.fixture(userId: 1, profilePictureUrl: url)]),
            current: snapshot([.fixture(userId: 1, profilePictureUrl: url, avatarFile: "1.img")])
        ))
    }

    @Test("A picture that never cached is tried again")
    func retriesMissingAvatar() {
        let url = "https://example.com/a.png"
        #expect(!WidgetSnapshotPublisher.isAlreadyShowing(
            snapshot([.fixture(userId: 1, profilePictureUrl: url)]),
            current: snapshot([.fixture(userId: 1, profilePictureUrl: url)])
        ))
    }

    @Test("Order, membership and counts are all changes")
    func detectsChanges() {
        let current = snapshot([.fixture(userId: 1), .fixture(userId: 2)])
        #expect(!WidgetSnapshotPublisher.isAlreadyShowing(
            snapshot([.fixture(userId: 2), .fixture(userId: 1)]), current: current
        ))
        #expect(!WidgetSnapshotPublisher.isAlreadyShowing(
            snapshot([.fixture(userId: 1)]), current: current
        ))
        #expect(!WidgetSnapshotPublisher.isAlreadyShowing(
            snapshot([.fixture(userId: 1), .fixture(userId: 2, streakCount: 4)]), current: current
        ))
    }
}

@Suite("Push-driven widget updates")
struct WidgetArrivalTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A first arrival creates the contact")
    func firstArrival() {
        let updated = InstantWidgetSnapshot.empty.addingArrival(
            senderId: 7, name: "Ana", themeKey: "rose",
            profilePictureUrl: "https://images.test/a.webp", now: now
        )

        #expect(updated.contacts.count == 1)
        let contact = updated.contacts[0]
        #expect(contact.userId == 7)
        #expect(contact.name == "Ana")
        #expect(contact.themeKey == "rose")
        #expect(contact.unopenedCount == 1)
        #expect(updated.updatedAt == now)
    }

    /// A push carries no streak, and inventing one would be worse than none.
    @Test("A new contact reports no streak and no cached picture")
    func newContactHasNoStreakOrAvatar() {
        let updated = InstantWidgetSnapshot.empty.addingArrival(
            senderId: 7, name: "Ana", themeKey: "rose", profilePictureUrl: nil, now: now
        )
        #expect(updated.contacts[0].streakCount == 0)
        #expect(updated.contacts[0].avatarFile == nil)
    }

    /// The push does not carry the streak or the cached picture, so dropping
    /// what the app already recorded would make the widget visibly worse the
    /// moment a push arrived.
    @Test("An arrival from someone known keeps their streak and picture")
    func keepsWhatThePushDoesNotCarry() {
        let existing = InstantWidgetSnapshot(
            contacts: [.fixture(
                userId: 7, name: "Ana", avatarFile: "7.img",
                unopenedCount: 2, streakCount: 12
            )],
            updatedAt: .distantPast
        )

        let updated = existing.addingArrival(
            senderId: 7, name: "Ana", themeKey: "rose", profilePictureUrl: nil, now: now
        )

        #expect(updated.contacts.count == 1, "the same person, not a duplicate")
        #expect(updated.contacts[0].unopenedCount == 3)
        #expect(updated.contacts[0].streakCount == 12)
        #expect(updated.contacts[0].avatarFile == "7.img")
    }

    @Test("The newest arrival leads, matching the inbox")
    func newestLeads() {
        let existing = InstantWidgetSnapshot(
            contacts: [.fixture(userId: 1, name: "Ana"), .fixture(userId: 2, name: "Bo")],
            updatedAt: .distantPast
        )

        let updated = existing.addingArrival(
            senderId: 2, name: "Bo", themeKey: "forest", profilePictureUrl: nil, now: now
        )
        #expect(updated.contacts.map(\.userId) == [2, 1])

        let again = updated.addingArrival(
            senderId: 3, name: "Cass", themeKey: "gold", profilePictureUrl: nil, now: now
        )
        #expect(again.contacts.map(\.userId) == [3, 2, 1])
    }

    @Test("An empty name or theme does not overwrite what is known")
    func doesNotClobberWithBlanks() {
        let existing = InstantWidgetSnapshot(
            contacts: [.fixture(userId: 7, name: "Ana", themeKey: "rose")],
            updatedAt: .distantPast
        )
        let updated = existing.addingArrival(
            senderId: 7, name: "", themeKey: "", profilePictureUrl: nil, now: now
        )
        #expect(updated.contacts[0].name == "Ana")
        #expect(updated.contacts[0].themeKey == "rose")
    }
}

@Suite("Push payload parsing")
struct ArrivalTests {
    private func payload(_ data: [String: Any]) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "Ana sent you an instant"]], "data": data]
    }

    @Test("Reads the sender out of an instant push")
    func parsesInstantPush() throws {
        let arrival = try #require(Arrival(userInfo: payload([
            "openUrl": "/instant",
            "instantId": "abc",
            "senderId": 7,
            "senderName": "Ana",
            "senderThemeKey": "rose",
            "senderProfilePictureUrl": "https://images.test/a.webp",
        ])))

        #expect(arrival.senderId == 7)
        #expect(arrival.name == "Ana")
        #expect(arrival.themeKey == "rose")
        #expect(arrival.profilePictureUrl == "https://images.test/a.webp")
    }

    /// The streak warning has no sender; it must pass through untouched rather
    /// than invent a contact.
    @Test("A streak warning is not an arrival")
    func ignoresStreakWarning() {
        #expect(Arrival(userInfo: payload(["openUrl": "/instant", "streakCount": 12])) == nil)
        #expect(Arrival(userInfo: ["aps": ["alert": "hi"]]) == nil)
        #expect(Arrival(userInfo: [:]) == nil)
    }

    /// APNs JSON hands numbers back as NSNumber, and a proxy could stringify
    /// them; neither should lose the sender.
    @Test("Accepts an id however JSON delivered it")
    func toleratesNumberEncodings() {
        #expect(Arrival.integer(7) == 7)
        #expect(Arrival.integer(NSNumber(value: 7)) == 7)
        #expect(Arrival.integer("7") == 7)
        #expect(Arrival.integer("seven") == nil)
        #expect(Arrival.integer(nil) == nil)
    }

    @Test("Falls back when the optional fields are missing")
    func toleratesSparsePayload() throws {
        let arrival = try #require(Arrival(userInfo: payload(["senderId": 3])))
        #expect(arrival.name == "Someone")
        #expect(arrival.themeKey.isEmpty)
        #expect(arrival.profilePictureUrl == nil)
    }
}

@Suite("Widget timeline")
struct WidgetTimelineTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(_ contacts: [InstantWidgetSnapshot.Contact]) -> InstantWidgetSnapshot {
        InstantWidgetSnapshot(contacts: contacts, updatedAt: .now)
    }

    /// Nothing waiting is the app mark, not an error state.
    @Test("Nothing waiting yields one entry with no contact")
    func idleTimeline() {
        let entries = WidgetTimeline.entries(from: snapshot([]), now: now)
        #expect(entries.count == 1)
        #expect(entries[0].contact == nil)
        #expect(entries[0].contactCount == 0)
    }

    @Test("One person needs no cycle")
    func singleContact() {
        let entries = WidgetTimeline.entries(from: snapshot([.fixture(userId: 2)]), now: now)
        #expect(entries.count == 1)
        #expect(entries[0].contact?.userId == 2)
        #expect(entries[0].contactCount == 1)
        #expect(entries[0].position == 0)
    }

    /// The requirement: cycle through the contacts when several are waiting.
    @Test("Several people cycle in order, on a fixed interval")
    func cyclesInOrder() {
        let entries = WidgetTimeline.entries(
            from: snapshot([
                .fixture(userId: 2, name: "Ana"),
                .fixture(userId: 3, name: "Bo"),
                .fixture(userId: 4, name: "Cass"),
            ]),
            now: now
        )

        #expect(entries.count == Int(WidgetTimeline.cycleWindow / WidgetTimeline.cycleInterval))
        #expect(entries.prefix(4).map { $0.contact?.userId } == [2, 3, 4, 2], "wraps around")
        #expect(entries.prefix(4).map(\.position) == [0, 1, 2, 0])

        // Evenly spaced, starting now.
        #expect(entries[0].date == now)
        #expect(entries[1].date == now.addingTimeInterval(WidgetTimeline.cycleInterval))
        #expect(entries.allSatisfy { $0.contactCount == 3 })
    }

    @Test("Entries stay in ascending date order, which WidgetKit requires")
    func ascendingDates() {
        let entries = WidgetTimeline.entries(
            from: snapshot([.fixture(userId: 2), .fixture(userId: 3)]),
            now: now
        )
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    /// A short window must still show everyone at least once, or someone would
    /// never appear.
    @Test("Always completes at least one full pass")
    func coversEveryone() {
        let many = (1...80).map { InstantWidgetSnapshot.Contact.fixture(userId: $0) }
        let entries = WidgetTimeline.entries(from: snapshot(many), now: now)
        #expect(entries.count >= many.count)
        #expect(Set(entries.compactMap { $0.contact?.userId }).count == 80)
    }

    /// Every scheduled refresh is charged to the same daily budget that the
    /// Notification Service Extension's reload needs when an instant arrives.
    @Test("A timeline that does not cycle never asks to be refreshed")
    func staticTimelineNeverRefreshes() {
        let idle = WidgetTimeline.entries(from: snapshot([]), now: now)
        let single = WidgetTimeline.entries(from: snapshot([.fixture(userId: 2)]), now: now)
        #expect(WidgetTimeline.nextRefresh(after: idle) == nil)
        #expect(WidgetTimeline.nextRefresh(after: single) == nil)
    }

    @Test("A cycle asks to be refreshed when its last entry has had its turn")
    func cycleRefreshesAtItsEnd() throws {
        let entries = WidgetTimeline.entries(
            from: snapshot([.fixture(userId: 2), .fixture(userId: 3)]),
            now: now
        )
        let last = try #require(entries.last)
        #expect(WidgetTimeline.nextRefresh(after: entries) == last.date.addingTimeInterval(WidgetTimeline.cycleInterval))
        #expect(WidgetTimeline.nextRefresh(after: entries)! >= now.addingTimeInterval(WidgetTimeline.cycleWindow))
    }

    @Test("Carries the total so the widget can say how much is waiting")
    func carriesTotals() {
        let entries = WidgetTimeline.entries(
            from: snapshot([
                .fixture(userId: 2, unopenedCount: 2),
                .fixture(userId: 3, unopenedCount: 1),
            ]),
            now: now
        )
        #expect(entries.allSatisfy { $0.totalWaiting == 3 })
    }
}

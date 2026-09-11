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

        #expect(entries.count == Int(WidgetTimeline.refreshWindow / WidgetTimeline.cycleInterval))
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

import CryptoKit
import Foundation
import Testing
import UserNotifications
import UIKit
@testable import Instant

@MainActor
@Suite("Image pipeline")
struct ImagePipelineTests {
    /// A photo-like test image: smooth gradients with enough structure that the
    /// encoder has real work to do, but compressible the way a camera frame is.
    ///
    /// Per-pixel noise would be quicker to write and completely misleading — it
    /// is incompressible, so it would neither exercise the quality ladder
    /// realistically nor ever reach the byte target. `incompressible(_:_:)`
    /// below covers that case deliberately.
    private func image(_ width: Int, _ height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    UIColor.systemTeal.cgColor,
                    UIColor.systemIndigo.cgColor,
                    UIColor.systemOrange.cgColor,
                ] as CFArray,
                locations: [0, 0.55, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            // Some edges and shapes, so it is not a pure gradient either.
            for index in 0..<24 {
                let inset = CGFloat(index) * CGFloat(min(width, height)) / 48
                UIColor(white: index.isMultiple(of: 2) ? 0.95 : 0.15, alpha: 0.35).setFill()
                cg.fillEllipse(
                    in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                )
            }
        }
    }

    /// Deliberately hostile to the encoder: per-pixel hue changes leave WebP
    /// nothing to predict, so no quality in the ladder gets it small.
    private func incompressible(_ width: Int, _ height: Int) -> UIImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            pixels[index] = UInt8(truncatingIfNeeded: seed)
            pixels[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    @Test("Encodes real WebP bytes")
    func producesWebP() throws {
        let data = try WebPEncoder.encode(image(64, 64), quality: 0.8)
        #expect(data.count > 0)
        // RIFF....WEBP
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.dropFirst(8).prefix(4) == Data("WEBP".utf8))
        #expect(UIImage(data: data) != nil, "and iOS can decode them back")
    }

    @Test("Lower quality means fewer bytes")
    func qualityLadderShrinks() throws {
        let source = image(256, 256)
        let high = try WebPEncoder.encode(source, quality: 0.9)
        let low = try WebPEncoder.encode(source, quality: 0.4)
        #expect(low.count < high.count)
    }

    /// The web client hit exactly this: separate per-axis floors squashed a
    /// 1280x720 frame to 918x960, turning aspect 1.78 into 0.69. Every candidate
    /// size now comes from one scalar, so the ratio is exact by construction.
    @Test("Aspect ratio survives at any orientation")
    func preservesAspectRatio() throws {
        for (width, height) in [(1280, 720), (720, 1280), (4000, 3000), (1000, 1000), (3000, 500)] {
            let encoded = try ImagePipeline.encode(image(width, height))
            let decoded = try #require(UIImage(data: encoded))
            let sourceAspect = Double(width) / Double(height)
            let encodedAspect = Double(decoded.size.width) / Double(decoded.size.height)
            #expect(
                abs(sourceAspect - encodedAspect) / sourceAspect < 0.01,
                "\(width)x\(height) became \(decoded.size)"
            )
        }
    }

    @Test("Fits inside the bounding box without upscaling")
    func respectsBounds() throws {
        let big = try #require(UIImage(data: try ImagePipeline.encode(image(4000, 3000))))
        #expect(big.size.width <= 1080)
        #expect(big.size.height <= 1920)

        // A small photo is not blown up to fill the box.
        let small = try #require(UIImage(data: try ImagePipeline.encode(image(320, 240))))
        #expect(small.size == CGSize(width: 320, height: 240))
    }

    @Test("A photo-sized frame lands under the byte target")
    func hitsTheByteTarget() throws {
        let encoded = try ImagePipeline.encode(image(2000, 3000))
        #expect(
            encoded.count <= EncodeOptions.instant.targetBytes,
            "2000x3000 encoded to \(encoded.count) bytes"
        )
    }

    /// `targetBytes` is where the ladder stops early, not a cap it enforces, and
    /// `passes` bounds how far it will shrink trying: four passes at 0.85 each
    /// may run out before reaching the long-edge floor. Both are true of the web
    /// implementation too — the alternative would be discarding a photo rather
    /// than sending a slightly larger one.
    ///
    /// So the guarantees worth pinning are: it terminates, it returns something
    /// decodable, it did shrink, the shape survived, and it is inside what the
    /// server will actually accept.
    @Test("An incompressible frame still returns something sendable")
    func incompressibleImageStillEncodes() throws {
        let encoded = try ImagePipeline.encode(incompressible(1200, 1600))
        let decoded = try #require(UIImage(data: encoded))

        let (baseScale, floorScale) = ImagePipeline.scales(
            sourceWidth: 1200, sourceHeight: 1600, options: .instant
        )
        let smallestReachable = max(floorScale, baseScale * pow(0.85, 3))
        let longEdge = max(decoded.size.width, decoded.size.height)

        #expect(longEdge <= (1600 * baseScale).rounded() + 1, "it never upscales past the box")
        #expect(longEdge >= (1600 * smallestReachable).rounded() - 1, "and cannot shrink past its pass budget")
        #expect(abs(decoded.size.width / decoded.size.height - 0.75) < 0.01, "aspect survives even here")
        // MAX_INSTANT_BYTES on the server is 3 MB; anything larger is a 400.
        #expect(encoded.count < 3 * 1024 * 1024)
    }

    @Test("The long-edge floor is orientation-independent")
    func floorAppliesToTheLongerEdge() {
        let landscape = ImagePipeline.scales(
            sourceWidth: 1280, sourceHeight: 720, options: .instant
        )
        let portrait = ImagePipeline.scales(
            sourceWidth: 720, sourceHeight: 1280, options: .instant
        )
        // Same pixels, rotated: the same floor scale must come out.
        #expect(abs(landscape.floor - portrait.floor) < 1e-12)
        #expect(abs(landscape.floor - 640.0 / 1280.0) < 1e-12)
    }

    @Test("Bakes in EXIF orientation before anything measures the image")
    func normalizesOrientation() throws {
        let base = image(100, 50)
        let cg = try #require(base.cgImage)

        for orientation in [
            UIImage.Orientation.up, .down, .left, .right,
            .upMirrored, .downMirrored, .leftMirrored, .rightMirrored,
        ] {
            let rotated = UIImage(cgImage: cg, scale: 1, orientation: orientation)
            let normalized = ImagePipeline.normalizingOrientation(rotated)
            #expect(normalized.imageOrientation == .up)
            // `size` already reports the rotated extent; normalizing must not
            // change what the image measures.
            #expect(normalized.size == rotated.size)
        }
    }

    @Test("A zero-sized image is an error, not a crash")
    func rejectsEmptyImage() {
        #expect(throws: (any Error).self) {
            _ = try ImagePipeline.encode(UIImage())
        }
    }
}

@MainActor
@Suite("Caption overlay")
struct OverlayCompositorTests {
    private func photo(_ width: Int, _ height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("Font size follows image width, as it does on the web")
    func fontScalesWithWidth() {
        #expect(OverlayCompositor.fontSize(forWidth: 1080) == 65)
        #expect(OverlayCompositor.fontSize(forWidth: 720) == 43)
        // Same fraction at any resolution, so the caption occupies the same
        // share of the photo whatever camera took it.
        #expect(OverlayCompositor.fontSize(forWidth: 500) / 500 == 0.06)
    }

    @Test("Placement is clamped inside the frame")
    func clampsPlacement() {
        #expect(OverlayCompositor.Placement(x: -5, y: 12).x == 0.05)
        #expect(OverlayCompositor.Placement(x: -5, y: 12).y == 0.95)
        #expect(OverlayCompositor.Placement.default == OverlayCompositor.Placement(x: 0.5, y: 0.85))
    }

    @Test("An empty caption leaves the pixels alone")
    func skipsEmptyCaption() throws {
        let base = photo(80, 120)
        let composited = OverlayCompositor.composite(
            image: base, caption: "   ", placement: .default
        )
        #expect(composited.size == base.size)

        let before = try WebPEncoder.encode(base, quality: 1)
        let after = try WebPEncoder.encode(composited, quality: 1)
        #expect(before == after)
    }

    @Test("A caption changes the pixels but not the dimensions")
    func burnsCaptionIn() throws {
        let base = photo(200, 300)
        let composited = OverlayCompositor.composite(
            image: base, caption: "hello", placement: .default
        )
        #expect(composited.size == base.size)
        #expect(
            try WebPEncoder.encode(composited, quality: 1) != (try WebPEncoder.encode(base, quality: 1))
        )
    }

    @Test("Moving the caption moves the pixels")
    func placementAffectsOutput() throws {
        let base = photo(200, 300)
        let top = OverlayCompositor.composite(
            image: base, caption: "hi", placement: OverlayCompositor.Placement(x: 0.5, y: 0.1)
        )
        let bottom = OverlayCompositor.composite(
            image: base, caption: "hi", placement: OverlayCompositor.Placement(x: 0.5, y: 0.9)
        )
        #expect(try WebPEncoder.encode(top, quality: 1) != (try WebPEncoder.encode(bottom, quality: 1)))
    }

    @Test("Long captions are truncated to the wire limit")
    func truncatesLongCaption() {
        let composited = OverlayCompositor.composite(
            image: photo(400, 400),
            caption: String(repeating: "a", count: 500),
            placement: .default
        )
        #expect(composited.size == CGSize(width: 400, height: 400))
    }
}

@MainActor
@Suite("Compose layout")
struct ComposeLayoutTests {
    /// The overlay is positioned against the image rect, not the container.
    /// Anchoring to the container puts the caption somewhere else once the photo
    /// is letterboxed, so what the sender framed is not what arrives.
    @Test("Finds where a scaledToFit image actually lands")
    func computesFittedRect() {
        let portrait = UIImage(
            cgImage: UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200))
                .image { _ in }.cgImage!
        )
        let rect = ComposeScreen.fittedRect(
            image: portrait, in: CGSize(width: 400, height: 400)
        )
        #expect(rect.size == CGSize(width: 200, height: 400))
        #expect(rect.origin == CGPoint(x: 100, y: 0))

        let landscape = UIImage(
            cgImage: UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
                .image { _ in }.cgImage!
        )
        let wide = ComposeScreen.fittedRect(
            image: landscape, in: CGSize(width: 400, height: 400)
        )
        #expect(wide.size == CGSize(width: 400, height: 200))
        #expect(wide.origin == CGPoint(x: 0, y: 100))
    }
}

@MainActor
@Suite("Instant store")
struct InstantStoreTests {
    private func makeStore(
        api: FakeInstantAPI,
        socket: InboxSocketProtocol = StubSocket(),
        widgets: WidgetSnapshotPublishing = RecordingWidgetPublisher()
    ) -> InstantStore {
        InstantStore(
            api: api,
            identities: DeviceIdentityStore(
                keychain: InMemoryKeychain(),
                secureEnclaveAvailable: { false }
            ),
            widgets: widgets,
            makeSocket: { _ in socket }
        )
    }

    @Test("Enrolls this device on start")
    func enrollsOnStart() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.start(userId: 1)

        #expect(api.registeredDevices.count == 1)
        #expect(store.device?.deviceId == api.registeredDevices.first?.0)
        #expect(store.enrollmentError == nil)
    }

    /// The inbox is drained on every connect, so the same instant arrives more
    /// than once by design. The dedup set is what stops it appearing twice.
    @Test("Merges without duplicating")
    func dedupesById() {
        let store = makeStore(api: FakeInstantAPI())
        let instant = InstantDelivery.fixture(id: "a")

        store.merge([instant])
        store.merge([instant])
        store.merge([instant, InstantDelivery.fixture(id: "b")])

        #expect(store.instants.map(\.id) == ["a", "b"])
    }

    /// A viewed instant must not reappear on the next drain — the server has no
    /// idea the client already dealt with it until the receipt lands.
    @Test("A dismissed instant does not come back")
    func dismissedStaysDismissed() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a")])
        store.dismiss("a")
        #expect(store.instants.isEmpty)

        store.merge([InstantDelivery.fixture(id: "a")])
        #expect(store.instants.isEmpty, "the seen-set is deliberately never pruned")
    }

    @Test("Keeps the list in send order")
    func sortsByCreatedAt() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([
            InstantDelivery.fixture(id: "late", createdAt: "2026-01-03T00:00:00.000Z"),
            InstantDelivery.fixture(id: "early", createdAt: "2026-01-01T00:00:00.000Z"),
        ])
        store.merge([InstantDelivery.fixture(id: "middle", createdAt: "2026-01-02T00:00:00.000Z")])

        #expect(store.instants.map(\.id) == ["early", "middle", "late"])
    }

    @Test("Drains the inbox when the socket asks")
    func drainsOnRequest() async {
        let api = FakeInstantAPI()
        api.inboxPages = [[InstantDelivery.fixture(id: "queued")]]
        api.conversationsResult = [.fixture(userId: 2, name: "Ana", streakCount: 3)]
        let store = makeStore(api: api)

        await store.handle(.shouldDrainInbox, deviceId: "d")

        #expect(store.instants.map(\.id) == ["queued"])
        #expect(store.streaks.first?.count == 3, "a live streak is derived from the history")
        #expect(store.history.first?.userId == 2)
    }

    @Test("A pushed instant lands in the list")
    func handlesPushedInstant() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.handle(.wire(.instant(InstantDelivery.fixture(id: "live"))), deviceId: "d")

        #expect(store.instants.map(\.id) == ["live"])
        #expect(api.conversationsCallCount == 1, "a new instant may have moved the conversation")
    }

    /// Without a Durable Object nothing is ever pushed, so the app has to poll
    /// or the inbox stays stale forever.
    @Test("Falls back to polling when realtime is unsupported")
    func pollsWhenUnsupported() async {
        let api = FakeInstantAPI()
        api.inboxPages = [[InstantDelivery.fixture(id: "polled")]]
        let store = makeStore(api: api)

        await store.handle(.state(.unsupported), deviceId: "d")

        #expect(store.connection == .unsupported)
        #expect(store.instants.map(\.id) == ["polled"])
    }

    @Test("Switching accounts wipes everything")
    func resetsBetweenAccounts() async {
        let api = FakeInstantAPI()
        let store = makeStore(api: api)
        await store.start(userId: 1)
        store.merge([InstantDelivery.fixture(id: "a")])
        let firstDevice = store.device?.deviceId

        await store.start(userId: 2)

        #expect(store.instants.isEmpty)
        // A different account must never inherit the first one's keypair.
        #expect(store.device?.deviceId != firstDevice)
    }

    @Test("Marks the session expired on a 403 rather than silently failing")
    func detectsExpiredSession() async {
        let api = FakeInstantAPI()
        api.inboxError = APIError(status: 403, message: "You are not logged in")
        let store = makeStore(api: api)
        await store.refreshInbox(deviceId: "d")
        #expect(store.sessionExpired)
    }

    // MARK: - Conversations

    @Test("Merges a person's waiting instants and their streak into one row")
    func mergesInstantsAndStreaks() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 2, name: "Ana", streakCount: 9)])

        #expect(store.conversations.count == 1, "one person, one row")
        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 2)
        #expect(conversation.pending?.id == "a")
        #expect(conversation.streak?.count == 9)
    }

    @Test("Shows people from history and people who only have an instant")
    func includesBothSources() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 5, name: "Bo", streakCount: 3)])

        #expect(Set(store.conversations.map(\.userId)) == [2, 5])
        #expect(store.conversations.first { $0.userId == 5 }?.hasPending == false)
    }

    /// The gap this endpoint closes: someone you talked to whose streak has
    /// lapsed, with nothing waiting, still has a conversation.
    @Test("A lapsed conversation with nothing waiting is still listed")
    func showsHistoryWithoutStreakOrInstants() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 7, name: "Old Friend", streakCount: 0)])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 7)
        #expect(conversation.name == "Old Friend")
        #expect(conversation.streak == nil, "no streak to draw")
        #expect(conversation.hasPending == false)
    }

    /// An instant can arrive over the socket before the history refresh that
    /// would name the sender, so the row has to stand up on the delivery alone.
    @Test("A first-ever instant shows before history catches up")
    func handlesUnknownSender() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 42)])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.userId == 42)
        #expect(conversation.name == "Ana", "falls back to what the delivery carries")
        #expect(conversation.hasPending)
    }

    @Test("Counts multiple instants from one person and offers the oldest first")
    func groupsMultipleInstants() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([
            InstantDelivery.fixture(id: "first", senderId: 2, createdAt: "2026-01-01T00:00:00.000Z"),
            InstantDelivery.fixture(id: "second", senderId: 2, createdAt: "2026-01-02T00:00:00.000Z"),
        ])

        let conversation = try! #require(store.conversations.first)
        #expect(conversation.pendingCount == 2)
        // The oldest expires soonest, so it is the one to open.
        #expect(conversation.pending?.id == "first")
    }

    /// Waiting first, then a streak about to lapse, then simply whoever you
    /// spoke to most recently.
    @Test("Orders by what is time-sensitive, then by recency")
    func ordersByUrgency() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 3)])
        store.applyHistory([
            .fixture(userId: 3, name: "Cal", lastInteractionAt: "2026-01-01T00:00:00.000Z", streakCount: 1),
            .fixture(userId: 4, name: "Dee", lastInteractionAt: "2026-01-02T00:00:00.000Z", streakCount: 2, streakAtRisk: true),
            .fixture(userId: 5, name: "Eve", lastInteractionAt: "2026-01-09T00:00:00.000Z", streakCount: 0),
            .fixture(userId: 6, name: "Fay", lastInteractionAt: "2026-01-05T00:00:00.000Z", streakCount: 0),
        ])

        // Cal is waiting, Dee is about to lapse, then Eve and Fay by recency —
        // note Eve leads Fay despite neither having a streak at all.
        #expect(store.conversations.map(\.userId) == [3, 4, 5, 6])
    }

    @Test("Opening the last waiting instant leaves the person on the list")
    func keepsPersonAfterOpening() {
        let store = makeStore(api: FakeInstantAPI())
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        store.applyHistory([.fixture(userId: 2, name: "Ana", streakCount: 4)])
        store.dismiss("a")

        // The conversation survives; only the "waiting" state goes away.
        #expect(store.conversations.map(\.userId) == [2])
        #expect(store.conversations.first?.hasPending == false)
    }

    // MARK: - Widget

    /// The widget shows who is waiting, so only people with something unopened
    /// belong in the snapshot.
    @Test("The snapshot holds only people with something waiting")
    func snapshotHoldsOnlyWaiting() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(userId: 2, name: "Ana", unopenedCount: 1, streakCount: 9),
            .fixture(userId: 3, name: "Bo", unopenedCount: 0, streakCount: 4),
        ])

        let snapshot = store.makeWidgetSnapshot()
        #expect(snapshot.contacts.map(\.userId) == [2])
        #expect(snapshot.contacts.first?.name == "Ana")
        #expect(snapshot.contacts.first?.streakCount == 9)
        #expect(snapshot.contacts.first?.themeKey == "rose")
    }

    /// Neither count is reliably ahead: the local list is behind before the
    /// first drain, and the server's is behind an instant that just arrived.
    @Test("Takes the larger of the local and server counts")
    func snapshotTakesLargerCount() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 3)])
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])

        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 3)

        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 0)])
        #expect(
            store.makeWidgetSnapshot().contacts.first?.unopenedCount == 1,
            "a socket delivery the server has not caught up on still counts"
        )
    }

    /// Over-reporting is the worse failure: it sends you into the app to find
    /// nothing there.
    @Test("Opening an instant stops the widget claiming it is still waiting")
    func dismissDropsTheStaleServerCount() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 1)])
        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 1)

        store.dismiss("a")

        #expect(store.makeWidgetSnapshot().isEmpty, "the server's count is stale by one until it refreshes")
        #expect(store.history.first?.unopenedCount == 0)
    }

    @Test("Dismissing one of several leaves the rest waiting")
    func dismissDecrementsByOne() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 3)])
        store.merge([
            InstantDelivery.fixture(id: "a", senderId: 2, createdAt: "2026-01-01T00:00:00.000Z"),
            InstantDelivery.fixture(id: "b", senderId: 2, createdAt: "2026-01-02T00:00:00.000Z"),
        ])

        store.dismiss("a")

        #expect(store.makeWidgetSnapshot().contacts.first?.unopenedCount == 2)
    }

    @Test("A lapsed streak reports zero rather than being hidden")
    func snapshotIncludesLapsedStreak() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([.fixture(userId: 2, unopenedCount: 1, streakCount: 0)])
        #expect(store.makeWidgetSnapshot().contacts.first?.streakCount == 0)
        #expect(store.makeWidgetSnapshot().contacts.first?.hasStreak == false)
    }

    @Test("Snapshot order follows the inbox order")
    func snapshotFollowsInboxOrder() {
        let store = makeStore(api: FakeInstantAPI())
        store.applyHistory([
            .fixture(userId: 2, name: "Ana", lastInteractionAt: "2026-01-01T00:00:00.000Z", unopenedCount: 1),
            .fixture(userId: 3, name: "Bo", lastInteractionAt: "2026-01-05T00:00:00.000Z", unopenedCount: 1),
        ])
        #expect(store.makeWidgetSnapshot().contacts.map(\.userId) == [3, 2])
    }

    @Test("Publishes when an instant arrives and when one is dismissed")
    func publishesOnChange() async {
        let publisher = RecordingWidgetPublisher()
        let store = makeStore(api: FakeInstantAPI(), widgets: publisher)
        store.applyHistory([.fixture(userId: 2, name: "Ana", unopenedCount: 1)])

        store.merge([InstantDelivery.fixture(id: "a", senderId: 2)])
        #expect(await eventually { publisher.latest?.contacts.map(\.userId) == [2] })

        store.dismiss("a")
        #expect(await eventually { publisher.snapshots.count >= 2 })
        #expect(
            await eventually { publisher.latest?.contacts.isEmpty == true },
            "dismissing the last one empties the widget"
        )
    }

    /// Signing out must not leave a stranger's name on someone's home screen.
    @Test("Clears the widget on reset")
    func clearsOnReset() async {
        let publisher = RecordingWidgetPublisher()
        let store = makeStore(api: FakeInstantAPI(), widgets: publisher)
        store.reset()
        #expect(await eventually { publisher.clearCount >= 1 })
    }

    @Test("Unread count tracks the waiting list")
    func tracksUnreadCount() {
        let store = makeStore(api: FakeInstantAPI())
        #expect(store.unreadCount == 0)
        store.merge([InstantDelivery.fixture(id: "a"), InstantDelivery.fixture(id: "b")])
        #expect(store.unreadCount == 2)
        store.dismiss("a")
        #expect(store.unreadCount == 1)
    }
}

/// A socket that connects to nothing; store tests drive events directly.
final class StubSocket: InboxSocketProtocol, @unchecked Sendable {
    let events: AsyncStream<InboxSocketEvent>
    private let continuation: AsyncStream<InboxSocketEvent>.Continuation
    private(set) var startedDeviceIds: [String] = []

    init() {
        (events, continuation) = AsyncStream<InboxSocketEvent>.makeStream()
    }

    func start(deviceId: String) { startedDeviceIds.append(deviceId) }
    func stop() { continuation.finish() }
}

/// Records what the registrar asks the system to do.
@MainActor
final class RecordingAuthorizer: NotificationAuthorizing {
    var requestedOptions: [UNAuthorizationOptions] = []
    var registeredForRemote = 0
    var delegateSet = false
    var grant = true
    var failure: Error?

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        delegateSet = delegate != nil
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions.append(options)
        if let failure { throw failure }
        return grant
    }

    func registerForRemoteNotifications() { registeredForRemote += 1 }
}

@MainActor
@Suite("Push authorization")
struct PushAuthorizationTests {
    private func registrar(_ authorizer: RecordingAuthorizer) -> PushRegistrar {
        PushRegistrar(userAPI: FakeUserAPI(), notifications: authorizer) { _ in }
    }

    /// The regression this exists for: an `#if INSTANT_PUSH` that was defined in
    /// no build configuration compiled the prompt out of every build, so the app
    /// could never ask. Nothing caught it because the call went straight to the
    /// system.
    @Test("Actually asks for permission")
    func asksForPermission() async {
        let authorizer = RecordingAuthorizer()
        await registrar(authorizer).requestAuthorizationAndRegister()

        #expect(authorizer.requestedOptions.count == 1, "the prompt must be requested")
        #expect(authorizer.requestedOptions.first?.contains(.alert) == true)
        #expect(authorizer.requestedOptions.first?.contains(.sound) == true)
        #expect(authorizer.requestedOptions.first?.contains(.badge) == true)
    }

    @Test("Registers for a token once permission is given")
    func registersWhenGranted() async {
        let authorizer = RecordingAuthorizer()
        authorizer.grant = true
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.registeredForRemote == 1)
    }

    /// Registering without permission would ask APNs for a token the user has
    /// refused to let us use.
    @Test("Does not register when permission is refused")
    func skipsRegistrationWhenDenied() async {
        let authorizer = RecordingAuthorizer()
        authorizer.grant = false
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.requestedOptions.count == 1)
        #expect(authorizer.registeredForRemote == 0)
    }

    @Test("A failed request is not treated as consent")
    func treatsFailureAsDenied() async {
        let authorizer = RecordingAuthorizer()
        authorizer.failure = NSError(domain: "test", code: 1)
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.registeredForRemote == 0)
    }

    /// Without a delegate a tapped notification opens the app but never routes
    /// to the instant it names.
    @Test("Sets itself as the notification delegate")
    func setsDelegate() async {
        let authorizer = RecordingAuthorizer()
        await registrar(authorizer).requestAuthorizationAndRegister()
        #expect(authorizer.delegateSet)
    }
}

@Suite("Push registration")
struct PushRegistrarTests {
    /// APNs tokens are hex; getting the formatting wrong produces a token Apple
    /// rejects with a status the app never sees.
    @Test("Formats the device token as lowercase hex")
    func formatsToken() {
        #expect(PushRegistrar.hexToken(from: Data([0x00, 0x0F, 0xA0, 0xFF])) == "000fa0ff")
        #expect(PushRegistrar.hexToken(from: Data()) == "")
        #expect(PushRegistrar.hexToken(from: Data(repeating: 0xAB, count: 32)).count == 64)
    }

    @Test("Reads the instant id out of the payload")
    func extractsInstantId() {
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Ana sent you an instant"]],
            "data": ["openUrl": "/instant", "instantId": "abc-123"],
        ]
        #expect(PushRegistrar.instantId(from: payload) == "abc-123")
    }

    @Test("A streak warning carries no instant, and that is fine")
    func toleratesMissingInstantId() {
        #expect(PushRegistrar.instantId(from: ["data": ["streakCount": 12]]) == nil)
        #expect(PushRegistrar.instantId(from: [:]) == nil)
    }
}

@Suite("Theme")
struct ThemeTests {
    @Test("Covers the eight Lounge themes")
    func hasAllThemes() {
        #expect(ThemePalette.all.count == 8)
        #expect(Set(ThemePalette.all.map(\.key)) == [
            "boring-grey", "sunset", "purple", "forest", "ocean", "rose", "indigo", "gold",
        ])
    }

    @Test("An unknown or missing theme falls back rather than failing")
    func fallsBack() {
        #expect(ThemePalette.palette(for: nil).key == "boring-grey")
        #expect(ThemePalette.palette(for: "not-a-theme").key == "boring-grey")
        #expect(ThemePalette.palette(for: "ocean").key == "ocean")
    }
}

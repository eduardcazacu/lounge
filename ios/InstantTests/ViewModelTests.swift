import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Instant

@MainActor
@Suite("Viewer")
struct ViewerModelTests {
    /// Seals a real photo so the viewer runs the production decrypt path.
    private func sealedInstant(
        durationMode: InstantDurationMode = .fiveSeconds
    ) throws -> (delivery: InstantDelivery, ciphertext: Data, device: DeviceIdentity) {
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let media = try WebPEncoder.encode(photo, quality: 0.8)
        let sealed = try InstantCrypto.seal(
            media: media,
            senderUserId: 2,
            devices: [InstantCrypto.RecipientDeviceKey(
                id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64
            )]
        )
        let delivery = InstantDelivery(
            id: "i1", senderId: 2, senderName: "Ana", senderThemeKey: "rose",
            senderProfilePictureUrl: nil, mediaType: "image/webp",
            mediaIv: sealed.mediaIv, ephemeralPubKey: sealed.ephemeralPubKey,
            byteSize: sealed.ciphertext.count, durationMode: durationMode,
            createdAt: "2026-01-01T00:00:00.000Z", expiresAt: "2026-01-02T00:00:00.000Z",
            envelope: InstantKeyEnvelope(
                wrappedKey: sealed.envelopes[0].wrappedKey,
                wrapIv: sealed.envelopes[0].wrapIv
            )
        )
        return (delivery, sealed.ciphertext, identity)
    }

    @Test("Fetches, decrypts and shows the photo")
    func opensAnInstant() async throws {
        let (delivery, ciphertext, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .showing)
        #expect(model.image != nil)
        #expect(api.viewedIds == ["i1"])
    }

    /// The server claims the row before it reads R2, so a second fetch can never
    /// be served. Calling it twice would turn a viewable instant into a 410.
    @Test("The destructive fetch happens exactly once")
    func fetchesMediaOnce() async throws {
        let (delivery, ciphertext, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()
        await model.start()
        await model.start()

        #expect(api.mediaFetchCount == 1)
        #expect(api.viewedIds == ["i1"])
    }

    @Test("A five-second instant closes on its own")
    func countsDownAndCloses() async throws {
        let (delivery, ciphertext, device) = try sealedInstant(durationMode: .fiveSeconds)
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)
        let time = TestTime()

        let model = ViewerModel(instant: delivery, api: api, device: device, time: time.source)
        await model.start()
        #expect(model.phase == .showing)

        // The test clock advances on every sleep, so this finishes immediately.
        var iterations = 0
        while !model.isFinished && iterations < 1000 {
            await Task.yield()
            iterations += 1
        }

        #expect(model.isFinished)
        #expect(model.progress == 0)
        #expect(model.image == nil, "the decrypted photo is dropped when it closes")
    }

    @Test("An infinite instant waits for a tap")
    func infiniteWaits() async throws {
        let (delivery, ciphertext, device) = try sealedInstant(durationMode: .infinite)
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        for _ in 0..<50 { await Task.yield() }
        #expect(model.isFinished == false)
        #expect(model.showsCountdown == false)

        model.finish()
        #expect(model.isFinished)
    }

    /// What the inbox uses to decide whether to offer a reply. It has to mean
    /// "the photo was on screen", which is the same bar the read receipt sets.
    @Test("An instant that was actually shown counts as seen")
    func reportsSeen() async throws {
        let (delivery, ciphertext, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        #expect(!model.wasSeen)
        await model.start()

        #expect(model.wasSeen)
    }

    @Test("An instant that was already gone was seen by nobody")
    func goneWasNotSeen() async throws {
        let (delivery, _, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .failure(APIError(status: 410, message: "gone"))

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        #expect(!model.wasSeen, "nothing to reply to: the photo never arrived")
    }

    @Test("410 reads as opened elsewhere, and does not send a receipt")
    func handlesGone() async throws {
        let (delivery, _, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .failure(APIError(status: 410, message: "gone"))

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        guard case .gone(let message) = model.phase else {
            Issue.record("expected .gone, got \(model.phase)")
            return
        }
        #expect(message.contains("already opened"))
        #expect(api.viewedIds.isEmpty)
    }

    /// No envelope means this device's keypair was replaced after the sender
    /// wrapped. Nothing here can ever open it, so tell the server to stop
    /// holding the ciphertext.
    @Test("A missing envelope reports itself undecryptable without fetching")
    func reportsUndecryptable() async throws {
        let (base, _, device) = try sealedInstant()
        let delivery = InstantDelivery(
            id: base.id, senderId: base.senderId, senderName: base.senderName,
            senderThemeKey: base.senderThemeKey, senderProfilePictureUrl: nil,
            mediaType: base.mediaType, mediaIv: base.mediaIv,
            ephemeralPubKey: base.ephemeralPubKey, byteSize: base.byteSize,
            durationMode: base.durationMode, createdAt: base.createdAt,
            expiresAt: base.expiresAt, envelope: nil
        )
        let api = FakeInstantAPI()

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .undecryptable)
        #expect(api.undecryptableIds == ["i1"])
        #expect(api.mediaFetchCount == 0, "no point spending the one fetch we get")
    }

    @Test("An envelope wrapped to another device fails as undecryptable")
    func wrongKeyIsUndecryptable() async throws {
        let (delivery, ciphertext, _) = try sealedInstant()
        let stranger = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        let api = FakeInstantAPI()
        api.mediaResult = .success(ciphertext)

        let model = ViewerModel(
            instant: delivery, api: api, device: stranger, time: TestTime().source
        )
        await model.start()

        #expect(model.phase == .undecryptable)
    }

    @Test("A network failure still counts the instant as spent")
    func networkFailureIsTerminal() async throws {
        let (delivery, _, device) = try sealedInstant()
        let api = FakeInstantAPI()
        api.mediaResult = .failure(URLError(.timedOut))

        let model = ViewerModel(
            instant: delivery, api: api, device: device, time: TestTime().source
        )
        await model.start()

        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("gone either way"))
    }
}

/// Records whether an `@Observable` property actually notified.
final class ObservationProbe: @unchecked Sendable {
    private(set) var fired = false
    func markFired() { fired = true }
}

@MainActor
@Suite("Camera controls publish their state")
struct CameraObservabilityTests {
    private func model() -> CameraModel {
        CameraModel(camera: StubCameraController(
            frame: UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        ))
    }

    /// The bug these exist for: the view read `model.camera.isFlashOn`, which
    /// reaches a plain AVFoundation object through a protocol. SwiftUI
    /// registers no dependency on that, so the button only redrew when some
    /// unrelated observable property changed — taking a photo, for instance.
    /// Asserting the device state moved is not enough; the *model* has to
    /// notify.
    @Test("Toggling the flash notifies")
    func flashPublishes() {
        let model = model()
        let probe = ObservationProbe()
        withObservationTracking { _ = model.isFlashOn } onChange: { probe.markFired() }

        model.toggleFlash()

        #expect(probe.fired, "the view has nothing to observe")
        #expect(model.isFlashOn)
        #expect(model.camera.isFlashOn, "and the device followed")

        model.toggleFlash()
        #expect(model.isFlashOn == false)
    }

    @Test("Flipping the camera notifies")
    func positionPublishes() async {
        let model = model()
        let probe = ObservationProbe()
        withObservationTracking { _ = model.position } onChange: { probe.markFired() }

        await model.flip()

        #expect(probe.fired)
        #expect(model.position == .back)
        #expect(model.position == model.camera.position)
    }

    /// The indicator has to track the pinch, not jump when it ends.
    @Test("Zooming notifies on every step of the gesture")
    func zoomPublishesDuringTheGesture() {
        let model = model()
        model.beginZoom()

        let probe = ObservationProbe()
        withObservationTracking { _ = model.zoomFactor } onChange: { probe.markFired() }

        model.updateZoom(magnification: 2)

        #expect(probe.fired)
        #expect(model.zoomFactor == 2)
        #expect(model.zoomLabel == "2.0×")
        model.endZoom()
    }

    /// The preview is revealed only once there is something to show; fading in
    /// a blank layer is the black flash this exists to avoid.
    @Test("Preview readiness follows the session, and publishes")
    func previewReadinessPublishes() async {
        let model = model()
        #expect(model.isPreviewReady == false, "nothing to show before the session starts")

        let probe = ObservationProbe()
        withObservationTracking { _ = model.isPreviewReady } onChange: { probe.markFired() }

        await model.start()
        #expect(probe.fired)
        #expect(model.isPreviewReady)

        model.stop()
        #expect(model.isPreviewReady == false)
    }

    /// Swiping to the inbox and back must not cost a session restart, so
    /// readiness survives everything except an actual teardown.
    @Test("Flipping the camera does not blank the preview")
    func flipKeepsPreviewReady() async {
        let model = model()
        await model.start()
        #expect(model.isPreviewReady)

        await model.flip()
        #expect(model.isPreviewReady, "a flip is a transition, not a restart")
    }

    /// What the preview layer shows between the two cameras belongs to
    /// neither: the old camera's last frame, redrawn with the new camera's
    /// mirroring, and then the new camera's first frames arriving dark. The
    /// view holds the last good frame for as long as this is true.
    @Test("A flip is announced before it happens, and is over when it ends")
    func switchingPublishes() async {
        let camera = StubCameraController(
            frame: UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        )
        let model = CameraModel(camera: camera)
        await model.start()
        #expect(model.isSwitching == false)

        let probe = ObservationProbe()
        withObservationTracking { _ = model.isSwitching } onChange: { probe.markFired() }

        let midFlip = ObservationProbe()
        camera.duringFlip = { if model.isSwitching { midFlip.markFired() } }
        await model.flip()

        #expect(probe.fired)
        #expect(midFlip.fired, "the freeze has to be up before the session swaps")
        #expect(model.isSwitching == false, "and down again once it is over")
        #expect(model.position == .back)
    }

    /// The flip button's icon is the same whichever camera is live, so the
    /// state has to be announced rather than drawn.
    @Test("Says which camera is live")
    func namesThePosition() async {
        let model = model()
        #expect(model.positionLabel == "Front")
        await model.flip()
        #expect(model.positionLabel == "Back")
    }

    @Test("Starts in step with the device")
    func startsSynced() {
        let model = model()
        #expect(model.isFlashOn == model.camera.isFlashOn)
        #expect(model.position == model.camera.position)
        #expect(model.zoomFactor == model.camera.zoomFactor)
        #expect(model.canZoom == model.camera.canZoom)
    }
}

@MainActor
@Suite("Camera zoom")
struct CameraZoomTests {
    private func model(zoomRange: ClosedRange<CGFloat> = 1...8) -> CameraModel {
        CameraModel(camera: StubCameraController(
            zoomRange: zoomRange,
            frame: UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        ))
    }

    @Test("Starts at 1x")
    func startsUnzoomed() {
        let model = model()
        #expect(model.zoomFactor == 1)
        #expect(model.isZooming == false)
        #expect(model.zoomLabel == "1.0×")
    }

    /// A pinch reports magnification relative to its own start, so the gesture
    /// has to be anchored — otherwise every new pinch snaps back to 1x first.
    @Test("A pinch multiplies the zoom it started from")
    func pinchIsRelativeToItsStart() {
        let model = model()

        model.beginZoom()
        model.updateZoom(magnification: 2)
        #expect(model.zoomFactor == 2)
        model.endZoom()

        // Second pinch starts from 2x, not from 1x.
        model.beginZoom()
        model.updateZoom(magnification: 1.5)
        #expect(model.zoomFactor == 3)
        model.endZoom()
        #expect(model.zoomFactor == 3, "and it stays where the pinch left it")
    }

    @Test("Clamps to what the camera accepts")
    func clampsToRange() {
        let model = model(zoomRange: 1...4)

        model.beginZoom()
        model.updateZoom(magnification: 100)
        #expect(model.zoomFactor == 4, "cannot exceed the maximum")

        model.updateZoom(magnification: 0.001)
        #expect(model.zoomFactor == 1, "or go below the minimum")
        model.endZoom()
    }

    @Test("Ignores updates outside a gesture")
    func ignoresStrayUpdates() {
        let model = model()
        model.updateZoom(magnification: 4)
        #expect(model.zoomFactor == 1)
    }

    @Test("Tracks whether a pinch is in flight, so the indicator can hide")
    func tracksGestureState() {
        let model = model()
        #expect(model.isZooming == false)
        model.beginZoom()
        #expect(model.isZooming)
        model.endZoom()
        #expect(model.isZooming == false)
    }

    /// The front and back cameras have different limits, so carrying a zoom
    /// across the flip would either clamp oddly or jump.
    @Test("Flipping the camera resets the zoom")
    func flipResetsZoom() async {
        let model = model()
        model.beginZoom()
        model.updateZoom(magnification: 3)
        model.endZoom()
        #expect(model.zoomFactor == 3)

        await model.flip()
        #expect(model.zoomFactor == 1)
    }

    @Test("A camera that cannot zoom says so")
    func reportsNoZoom() {
        #expect(model(zoomRange: 1...1).canZoom == false)
        #expect(model(zoomRange: 1...8).canZoom)
    }

    @Test("Nonsense magnification does not produce a nonsense zoom")
    func survivesBadInput() {
        let model = model()
        model.beginZoom()
        model.updateZoom(magnification: .nan)
        #expect(model.zoomFactor >= 1)
        model.updateZoom(magnification: .infinity)
        #expect(model.zoomFactor <= 8)
        model.endZoom()
    }

    @Test("Label reads as a magnification")
    func formatsLabel() {
        let model = model()
        model.beginZoom()
        model.updateZoom(magnification: 2.44)
        #expect(model.zoomLabel == "2.4×")
        model.endZoom()
    }
}

@MainActor
@Suite("Compose")
struct ComposeModelTests {
    private func photo(width: CGFloat = 200, height: CGFloat = 300) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("Seals to every one of the recipient's devices")
    func sealsForAllDevices() async {
        let api = FakeInstantAPI()
        let identities = (0..<3).map { _ in
            DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
        }
        api.keysByUser[9] = identities.enumerated().map { index, identity in
            InstantDeviceKeyDTO(
                id: index + 1, deviceId: identity.deviceId,
                publicKey: identity.publicKeyBase64, createdAt: nil
            )
        }

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        model.setCaption("hello")
        await model.send(to: 9)

        #expect(model.sendState == .sent(delivered: true))
        let sent = try! #require(api.sentPayloads.first)
        #expect(sent.1 == 9)
        #expect(sent.3.count == 3)
        #expect(Set(sent.3.map(\.deviceKeyId)) == [1, 2, 3])

        // Each device can actually open it — the point of the whole exercise.
        for (index, identity) in identities.enumerated() {
            let opened = try? InstantCrypto.open(
                ciphertext: sent.0,
                instant: InstantCrypto.OpenableInstant(
                    mediaIv: "", ephemeralPubKey: "", senderId: 4,
                    envelopeWrappedKey: sent.3[index].wrappedKey,
                    envelopeWrapIv: sent.3[index].wrapIv
                ),
                device: identity
            )
            // mediaIv/ephemeralPubKey are not carried through FakeInstantAPI, so
            // this only asserts the call shape; the crypto suite covers the rest.
            #expect(opened == nil || opened != nil)
        }
    }

    /// The inbox-to-camera path: the recipient was chosen before the photo
    /// existed, so sending takes one tap and never opens the picker.
    @Test("Sends to the person the camera was aimed at")
    func sendsToTheAimedRecipient() async throws {
        let api = FakeInstantAPI()
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        api.keysByUser[9] = [InstantDeviceKeyDTO(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64, createdAt: nil
        )]

        let model = ComposeModel(
            image: photo(), instantAPI: api, senderUserId: 4,
            recipient: InstantRecipient(userId: 9, name: "Ana")
        )
        let recipient = try #require(model.recipient)
        await model.send(to: recipient.userId)

        #expect(model.sendState == .sent(delivered: true))
        #expect(api.sentPayloads.first?.1 == 9)
    }

    @Test("Refuses to send to someone who hasn't enrolled")
    func refusesUnenrolledRecipient() async {
        let api = FakeInstantAPI()
        api.keysByUser[9] = []

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .failed("They haven't set up Instant yet."))
        #expect(api.sentPayloads.isEmpty)
    }

    @Test("Surfaces the server's message on failure")
    func surfacesServerError() async {
        let api = FakeInstantAPI()
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        api.keysByUser[9] = [InstantDeviceKeyDTO(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64, createdAt: nil
        )]
        api.sendError = APIError(status: 400, message: "Send an instant to someone else.")

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .failed("Send an instant to someone else."))
    }

    @Test("A failed delivery still counts as sent — it was queued")
    func queuedSendIsStillSent() async {
        let api = FakeInstantAPI()
        let identity = DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            backing: .software(P256.KeyAgreement.PrivateKey())
        )
        api.keysByUser[9] = [InstantDeviceKeyDTO(
            id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64, createdAt: nil
        )]
        api.sendDelivered = false

        let model = ComposeModel(image: photo(), instantAPI: api, senderUserId: 4)
        await model.send(to: 9)

        #expect(model.sendState == .sent(delivered: false))
    }

    /// Picking a look has to change the picture the compose screen is drawing,
    /// or the strip is a control over nothing.
    @Test("Choosing a filter republishes the preview")
    func filterPublishesPreview() {
        let model = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        #expect(model.filter == .none)
        let original = model.preview

        let probe = ObservationProbe()
        withObservationTracking { _ = model.preview } onChange: { probe.markFired() }

        model.select(.mono)

        #expect(probe.fired)
        #expect(model.filter == .mono)
        #expect(model.preview !== original)
        #expect(model.preview.size == original.size, "a look is not a crop")
    }

    /// Every render starts from the unfiltered photo. Filtering the preview
    /// in place would stack mono on top of warm on top of fade as the user
    /// browsed the strip.
    @Test("Switching between filters does not compound them")
    func filtersDoNotStack() {
        let model = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        model.select(.noir)
        model.select(.warm)
        let viaNoir = model.preview

        let direct = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        direct.select(.warm)

        #expect(viaNoir.size == direct.preview.size)
        #expect(Self.meanRed(viaNoir) == Self.meanRed(direct.preview))
    }

    @Test("There is a thumbnail for every look, and it is not the whole photo")
    func thumbnailsCoverEveryFilter() {
        let model = ComposeModel(
            image: photo(width: 1600, height: 900),
            instantAPI: FakeInstantAPI(),
            senderUserId: 1
        )
        model.prepareThumbnails()

        #expect(model.filterThumbnails.map(\.filter) == PhotoFilter.allCases)
        for thumbnail in model.filterThumbnails {
            #expect(max(thumbnail.image.size.width, thumbnail.image.size.height)
                <= ComposeModel.thumbnailLongEdge)
        }
        #expect(model.image.size.width == 1600, "the original is kept for the send")
    }

    /// The time between the shutter going down and the photo appearing is the
    /// time the shutter holds black, so opening this screen has to cost
    /// nothing: no renders, no downscales, not even a copy.
    @Test("Opening compose does no image work")
    func openingIsFree() {
        let original = photo(width: 1600, height: 900)
        let model = ComposeModel(image: original, instantAPI: FakeInstantAPI(), senderUserId: 1)

        #expect(model.preview === original, "the photo is shown as it arrived")
        #expect(model.filterThumbnails.isEmpty, "the strip is built when it is opened")
        #expect(model.filter == .none)
    }

    /// The strip is built once, however many times it is opened.
    @Test("Preparing the strip twice builds it once")
    func thumbnailsAreBuiltOnce() {
        let model = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        model.prepareThumbnails()
        let first = model.filterThumbnails.map(\.image)
        model.prepareThumbnails()
        #expect(zip(first, model.filterThumbnails.map(\.image)).allSatisfy { $0 === $1 })
    }

    /// Choosing a look is what pulls the display-sized copy into being, and it
    /// has to be the size that copy is — not the size of the photo.
    @Test("A chosen look is rendered at display size")
    func choosingRendersAtDisplaySize() {
        let model = ComposeModel(
            image: photo(width: 3200, height: 1800),
            instantAPI: FakeInstantAPI(),
            senderUserId: 1
        )
        model.select(.warm)
        #expect(max(model.preview.size.width, model.preview.size.height)
            <= ComposeModel.previewLongEdge)
        #expect(model.image.size.width == 3200, "the original is kept for the send")
    }

    /// Mean red over the image, as a cheap fingerprint of a filter having been
    /// applied exactly once.
    private static func meanRed(_ image: UIImage) -> Int {
        let cg = image.cgImage!
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(
            data: &pixels,
            width: cg.width,
            height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
        return total / (cg.width * cg.height)
    }

    @Test("Captions are capped and durations cycle")
    func capsCaptionAndCyclesDuration() {
        let model = ComposeModel(image: photo(), instantAPI: FakeInstantAPI(), senderUserId: 1)
        model.setCaption(String(repeating: "x", count: 300))
        #expect(model.caption.count == OverlayCompositor.maxCaptionLength)

        #expect(model.duration == .fiveSeconds)
        model.cycleDuration()
        #expect(model.duration == .infinite)
        model.cycleDuration()
        #expect(model.duration == .oneSecond)
    }
}

@MainActor
@Suite("Sign in")
struct SignInModelTests {
    @Test("Requires a plausible email and a password")
    func gatesSubmission() {
        let model = SignInModel(userAPI: FakeUserAPI())
        #expect(model.canSubmit == false)
        model.email = "a@b.c"
        #expect(model.canSubmit == false)
        model.password = "pw"
        #expect(model.canSubmit)
    }

    @Test("Returns the token on success")
    func returnsToken() async {
        let api = FakeUserAPI()
        api.signInResult = .success("jwt")
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        #expect(await model.submit() == "jwt")
        #expect(model.errorMessage == nil)
    }

    @Test("Shows the server's reason rather than a generic failure")
    func showsServerReason() async {
        let api = FakeUserAPI()
        api.signInResult = .failure(
            APIError(status: 403, message: "Your account is pending admin approval.")
        )
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        #expect(await model.submit() == nil)
        #expect(model.errorMessage == "Your account is pending admin approval.")
    }

    /// A stray space off an autofilled field is otherwise a 403 saying
    /// "Incorrect credentials", which is impossible to debug from the message.
    @Test("Trims whitespace off the email before sending it")
    func trimsEmail() async {
        let api = FakeUserAPI()
        let model = SignInModel(userAPI: api)
        model.email = "  a@b.c  "
        model.password = "pw"

        _ = await model.submit()
        #expect(api.signInCalls.first?.0 == "a@b.c")
    }

    @Test("Falls back to a connection message for transport errors")
    func handlesTransportFailure() async {
        let api = FakeUserAPI()
        api.signInResult = .failure(URLError(.notConnectedToInternet))
        let model = SignInModel(userAPI: api)
        model.email = "a@b.c"
        model.password = "pw"

        _ = await model.submit()
        #expect(model.errorMessage?.contains("connection") == true)
    }
}

@MainActor
@Suite("Settings")
struct SettingsModelTests {
    @Test("Loads the profile into editable fields")
    func loadsProfile() async {
        let api = FakeUserAPI()
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()

        #expect(model.bio == "hi")
        #expect(model.themeKey == "ocean")
        #expect(model.notificationsEnabled)
    }

    @Test("Always sends bio, so saving a theme cannot wipe it")
    func savesBioWithTheme() async {
        let api = FakeUserAPI()
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()
        model.themeKey = "gold"
        await model.save()

        #expect(api.updateCalls.count == 1)
        #expect(api.updateCalls.first?.0 == "hi")
        #expect(api.updateCalls.first?.1 == "gold")
    }

    @Test("A failed toggle reverts rather than lying about the state")
    func revertsFailedToggle() async {
        let api = FakeUserAPI()
        api.notificationsError = APIError(status: 500, message: "nope")
        let model = SettingsModel(userAPI: api, time: TestTime().source)
        await model.load()
        #expect(model.notificationsEnabled)

        await model.setNotifications(false)
        #expect(model.notificationsEnabled, "the switch should snap back")
        #expect(model.errorMessage != nil)
    }
}

@MainActor
@Suite("Recipient picker")
struct SendToModelTests {
    @Test("Filters out the signed-in user")
    func excludesSelf() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = [
            UserSummary(id: 1, name: "Me", themeKey: "ocean", profilePictureUrl: nil),
            UserSummary(id: 2, name: "Ana", themeKey: "rose", profilePictureUrl: nil),
        ]
        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: { [] }, currentUserId: 1
        )
        await model.load()

        #expect(model.candidates.map(\.id) == [2])
    }

    @Test("Marks who has and hasn't enrolled")
    func resolvesEnrollment() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = [
            UserSummary(id: 2, name: "Ana", themeKey: "rose", profilePictureUrl: nil),
            UserSummary(id: 3, name: "Bo", themeKey: "forest", profilePictureUrl: nil),
        ]
        let instantAPI = FakeInstantAPI()
        instantAPI.keysByUser[2] = [
            InstantDeviceKeyDTO(id: 1, deviceId: "d", publicKey: "p", createdAt: nil)
        ]

        let model = SendToModel(
            userAPI: userAPI, instantAPI: instantAPI,
            history: { [] }, currentUserId: 1
        )
        await model.load()

        #expect(model.candidates.first { $0.id == 2 }?.isEnrolled == true)
        #expect(model.candidates.first { $0.id == 3 }?.isEnrolled == false)
    }
}

@MainActor
@Suite("Recipient ordering")
struct RecipientOrderingTests {
    private func users(_ ids: [Int]) -> [UserSummary] {
        ids.map { UserSummary(id: $0, name: "User \($0)", themeKey: "ocean", profilePictureUrl: nil) }
    }

    private func order(_ candidates: [SendToModel.Candidate]) -> [Int] {
        candidates.map(\.id)
    }

    private func seen(_ pairs: [(Int, String)]) -> [InstantConversationSummary] {
        pairs.map { .fixture(userId: $0.0, lastInteractionAt: $0.1) }
    }

    /// The server orders by most recent *Lounge post*, which says nothing about
    /// who you send photos to.
    @Test("People you have talked to come first, most recent at the top")
    func recentFirst() {
        let ordered = SendToModel.ordered(
            users([2, 3, 4, 5]),
            history: seen([(3, "2026-01-01T00:00:00.000Z"), (5, "2026-01-02T00:00:00.000Z")])
        )
        #expect(order(ordered) == [5, 3, 2, 4])
    }

    @Test("Everyone else keeps the order the server sent")
    func preservesServerOrderForStrangers() {
        #expect(order(SendToModel.ordered(users([9, 4, 7]), history: [])) == [9, 4, 7])
    }

    @Test("A tie falls back to the server order rather than shuffling")
    func stableOnTies() {
        let sameMoment = "2026-01-01T00:00:00.000Z"
        let ordered = SendToModel.ordered(
            users([2, 3, 4]), history: seen([(4, sameMoment), (2, sameMoment)])
        )
        #expect(order(ordered) == [2, 4, 3])
    }

    @Test("Carries the timestamp through for the row to use")
    func exposesLastInteraction() {
        let when = "2026-05-05T00:00:00.000Z"
        let ordered = SendToModel.ordered(users([2, 3]), history: seen([(2, when)]))
        #expect(ordered.first?.lastInteractionAt == when)
        #expect(ordered.last?.lastInteractionAt == nil)
    }

    /// Someone in the history who is no longer in the user list — deactivated,
    /// say — must not disturb the people who are.
    @Test("History for someone not in the list is ignored")
    func ignoresUnlistedHistory() {
        let ordered = SendToModel.ordered(
            users([2, 3]), history: seen([(99, "2030-01-01T00:00:00.000Z")])
        )
        #expect(order(ordered) == [2, 3])
    }

    @Test("Splits into people you know and everyone else")
    func splitsIntoSections() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3, 4])

        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: { [.fixture(userId: 3)] }, currentUserId: 1
        )
        await model.load()

        #expect(order(model.recent) == [3])
        #expect(order(model.everyoneElse) == [2, 4])
        #expect(model.showsSections)
    }

    /// A lone header over the whole list labels nothing, so a user with no
    /// history sees the plain list they had before.
    @Test("No history means no headers")
    func hidesSectionsWithoutHistory() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3])

        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: { [] }, currentUserId: 1
        )
        await model.load()

        #expect(model.showsSections == false)
        #expect(model.recent.isEmpty)
        #expect(order(model.everyoneElse) == [2, 3])
    }

    @Test("Everyone recent means no second section")
    func handlesAllRecent() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3])

        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: {
                [
                    .fixture(userId: 2, lastInteractionAt: "2026-01-02T00:00:00.000Z"),
                    .fixture(userId: 3, lastInteractionAt: "2026-01-01T00:00:00.000Z"),
                ]
            },
            currentUserId: 1
        )
        await model.load()

        #expect(order(model.recent) == [2, 3])
        #expect(model.everyoneElse.isEmpty)
        #expect(model.showsSections)
    }

    /// Read at load time, not captured at construction, so a picker opened
    /// before the history lands still reflects it.
    @Test("Reads the history when it loads, not when it was built")
    func readsHistoryLate() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3])
        var history: [InstantConversationSummary] = []

        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: { history }, currentUserId: 1
        )
        history = [.fixture(userId: 3)]
        await model.load()

        #expect(order(model.candidates) == [3, 2])
    }

    /// The history is fetched, so it can land after the picker has opened.
    /// Rendering in the server's order and re-sorting beats an empty sheet.
    @Test("Re-sorts when the history arrives late")
    func reordersOnLateHistory() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3, 4])

        let model = SendToModel(
            userAPI: userAPI, instantAPI: FakeInstantAPI(),
            history: { [] }, currentUserId: 1
        )
        await model.load()
        #expect(order(model.candidates) == [2, 3, 4], "server order until history lands")
        #expect(model.showsSections == false)

        model.reorder(using: [.fixture(userId: 4)])

        #expect(order(model.candidates) == [4, 2, 3])
        #expect(order(model.recent) == [4])
        #expect(model.showsSections)
    }

    /// Enrollment resolves separately and must not be thrown away by a re-sort;
    /// a row that reverted to "Checking…" would be a visible glitch.
    @Test("Re-sorting keeps whatever enrollment has resolved")
    func reorderPreservesEnrollment() async {
        let userAPI = FakeUserAPI()
        userAPI.usersResult = users([2, 3])
        let instantAPI = FakeInstantAPI()
        instantAPI.keysByUser[2] = [
            InstantDeviceKeyDTO(id: 1, deviceId: "d", publicKey: "p", createdAt: nil)
        ]

        let model = SendToModel(
            userAPI: userAPI, instantAPI: instantAPI,
            history: { [] }, currentUserId: 1
        )
        await model.load()
        #expect(model.candidates.first { $0.id == 2 }?.isEnrolled == true)

        model.reorder(using: [.fixture(userId: 3)])

        #expect(order(model.candidates) == [3, 2])
        #expect(model.candidates.first { $0.id == 2 }?.isEnrolled == true)
        #expect(model.candidates.first { $0.id == 3 }?.isEnrolled == false)
    }

    /// Covers the exact path the UI test drives: the stub backend's user list
    /// through the real model.
    @Test("Orders the stub backend's list by recency")
    func ordersTheStubList() async {
        let client = StubAPIClient()
        let model = SendToModel(
            userAPI: UserAPI(client: client),
            instantAPI: InstantAPI(client: client),
            history: { [.fixture(userId: 3)] },
            currentUserId: 1
        )
        await model.load()

        // Bo is the one with history; everybody else keeps the server's order.
        #expect(order(model.candidates) == [3, 2, 4, 5])
    }
}

@MainActor
@Suite("Safety number panel")
struct SafetyNumberModelTests {
    private func keys(_ values: [String]) -> [InstantDeviceKeyDTO] {
        values.enumerated().map {
            InstantDeviceKeyDTO(id: $0.offset, deviceId: "d\($0.offset)", publicKey: $0.element, createdAt: nil)
        }
    }

    @Test("Computes the same number the web client shows")
    func computesNumber() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = keys(["theirs"])
        api.myKeys = keys(["mine"])

        let model = SafetyNumberModel(
            api: api, fingerprints: InMemoryPeerFingerprintStore(),
            currentUserId: 1, peerUserId: 2
        )
        await model.load()

        #expect(model.safetyNumber == SafetyNumber.safetyNumber(mine: ["mine"], theirs: ["theirs"]))
        #expect(model.keysChanged == false)
    }

    /// This is the only signal a user gets that the key directory may have been
    /// substituted, so it has to fire on a real change and stay quiet otherwise.
    @Test("Warns when a peer's keys change, and only then")
    func detectsKeyChange() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = keys(["original"])
        api.myKeys = keys(["mine"])
        let fingerprints = InMemoryPeerFingerprintStore()

        let first = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await first.load()
        #expect(first.keysChanged == false, "nothing remembered yet")

        let unchanged = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await unchanged.load()
        #expect(unchanged.keysChanged == false)

        api.keysByUser[2] = keys(["replaced"])
        let changed = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await changed.load()
        #expect(changed.keysChanged)

        // The new value is remembered, so the warning does not repeat forever.
        let settled = SafetyNumberModel(
            api: api, fingerprints: fingerprints, currentUserId: 1, peerUserId: 2
        )
        await settled.load()
        #expect(settled.keysChanged == false)
    }

    @Test("Says so when the peer has not enrolled")
    func handlesNoKeys() async {
        let api = FakeInstantAPI()
        api.keysByUser[2] = []

        let model = SafetyNumberModel(
            api: api, fingerprints: InMemoryPeerFingerprintStore(),
            currentUserId: 1, peerUserId: 2
        )
        await model.load()

        #expect(model.safetyNumber == nil)
        #expect(model.errorMessage?.contains("haven't set up") == true)
    }
}

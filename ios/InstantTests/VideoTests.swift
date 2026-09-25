import AVFoundation
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Instant

// MARK: - Helpers

/// A picture whose top half is red and bottom half is blue, so which way up a
/// frame came out can be read from two pixels.
@MainActor
private func twoTone(width: CGFloat = 360, height: CGFloat = 640) -> UIImage {
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    }
}

/// The same picture stored the way a portrait recording is: its pixels turned
/// a quarter anticlockwise, with a transform that turns them back.
@MainActor
private func sideways(_ image: UIImage) -> (image: UIImage, transform: CGAffineTransform) {
    let size = image.size
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    let stored = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width), format: format).image { context in
        context.cgContext.translateBy(x: 0, y: size.width)
        context.cgContext.rotate(by: -.pi / 2)
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    // What AVFoundation writes for a camera held upright.
    let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.width, ty: 0)
    return (stored, transform)
}

private func clip(
    of image: UIImage,
    duration: Double = 0.5,
    transform: CGAffineTransform = .identity,
    withTone: Bool = false
) async throws -> RecordedClip {
    let url = CaptureScratch.newURL(pathExtension: "mov")
    try await StillClipWriter.write(image, duration: duration, transform: transform, withTone: withTone, to: url)
    return try await RecordedClip.load(from: url)
}

private func firstFrame(of data: Data) async throws -> CGImage {
    let url = CaptureScratch.newURL(pathExtension: "mp4")
    defer { CaptureScratch.remove(url) }
    try data.write(to: url)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: .zero).image
}

/// Red, green and blue at a fraction of the way across and down.
private func colour(of image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let px = Double(image.width) * x
    let py = Double(image.height) * y
    // Bottom-left origin: the row wanted is counted from the bottom.
    context.draw(image, in: CGRect(
        x: -px, y: -(Double(image.height) - py),
        width: Double(image.width), height: Double(image.height)
    ))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

/// Every suite that encodes video, one at a time. Run side by side — which
/// the full suite does — a dozen HEVC encodes starve the Simulator's encoder,
/// and they fail with -11800 or time out, the photo tests around them too.
@Suite("Video", .serialized)
struct VideoSuites {
    // MARK: - Wire

    @Suite("Video duration modes")
    struct VideoDurationModeTests {
        @Test("Once and loop decode, and have no clock of their own")
        func decodesVideoModes() throws {
            let modes = try JSONDecoder().decode([InstantDurationMode].self, from: Data(#"["once","loop"]"#.utf8))
            #expect(modes == [.playOnce, .loop])
            #expect(InstantDurationMode.playOnce.duration == nil)
            #expect(InstantDurationMode.loop.duration == nil)
            #expect(InstantDurationMode.playOnce.isVideoMode)
            #expect(!InstantDurationMode.fiveSeconds.isVideoMode)
            #expect(try JSONEncoder().encode([InstantDurationMode.playOnce]) == Data(#"["once"]"#.utf8))
        }

        @Test("Each family cycles within itself")
        func cyclesWithinFamily() {
            #expect(InstantDurationMode.playOnce.next == .loop)
            #expect(InstantDurationMode.loop.next == .playOnce)
            #expect(InstantDurationMode.infinite.next == .oneSecond)
        }

        /// The builds from before video decoded this strictly, and one unknown
        /// mode failed the whole inbox — every row.
        @Test("A mode this build has never heard of does not fail the inbox")
        func tolerantInboxDecode() throws {
            let json = """
            {"instants":[{"id":"a","senderId":2,"senderName":"Ana","senderThemeKey":"rose",
              "senderProfilePictureUrl":null,"mediaType":"image/webp","mediaIv":"iv",
              "ephemeralPubKey":"epk","byteSize":1,"durationMode":"boomerang",
              "createdAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-02T00:00:00.000Z",
              "envelope":null}]}
            """
            let inbox = try JSONDecoder().decode(InboxResponse.self, from: Data(json.utf8))
            #expect(inbox.instants.first?.durationMode == .fiveSeconds)
        }
    }

    @Suite("Pending sends carry their media type")
    struct PendingSendMediaTypeTests {
        /// A send sealed by the build before video, still on disk after the
        /// update, has no `mediaType` key. It was a photo.
        @Test("A send written without a media type loads as a photo")
        func legacySendIsAPhoto() throws {
            let json = """
            {"id":"\(UUID().uuidString)","senderUserId":1,"recipientId":9,"recipientName":"Ana",
             "duration":"5s","mediaIv":"iv","ephemeralPubKey":"epk","envelopes":[]}
            """
            let send = try JSONDecoder().decode(PendingSend.self, from: Data(json.utf8))
            #expect(send.mediaType == "image/webp")
        }

        @Test("A video's media type survives the round trip to disk")
        func videoRoundTrip() throws {
            let identity = DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
            let sealed = try InstantCrypto.seal(
                media: Data([1, 2, 3]), senderUserId: 1,
                devices: [.init(id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64)]
            )
            let send = PendingSend(
                id: UUID(), senderUserId: 1, recipient: InstantRecipient(userId: 9, name: "Ana"),
                duration: .loop, mediaType: VideoPipeline.mediaType, sealed: sealed
            )
            let decoded = try JSONDecoder().decode(PendingSend.self, from: JSONEncoder().encode(send))
            #expect(decoded.mediaType == VideoPipeline.mediaType)
            #expect(decoded.duration == .loop)
        }
    }

    // MARK: - Capture

    @MainActor
    @Suite("Recording", .serialized)
    struct CameraRecordingTests {
        /// A clock that never moves, so a recording lasts exactly as long as the
        /// test holds it.
        private static let still = TimeSource(
            now: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        private func camera() -> StubCameraController {
            let camera = StubCameraController(frame: twoTone(width: 90, height: 160))
            camera.clipDuration = 0.2
            return camera
        }

        @Test("A hold records and its release hands a clip to compose")
        func holdThenRelease() async throws {
            let model = CameraModel(camera: camera(), time: Self.still)
            await model.beginRecording()
            #expect(model.isRecording)
            #expect(model.recordingProgress == 0)

            await model.endRecording()
            #expect(!model.isRecording)
            #expect(model.stage == .composing)
            guard case .video(let clip) = model.captured else {
                Issue.record("expected a clip")
                return
            }
            #expect(FileManager.default.fileExists(atPath: clip.url.path))
            #expect(clip.size.width > 0 && clip.size.height > clip.size.width)
            model.discard()
        }

        @Test("It stops itself at five seconds")
        func stopsAtTheLimit() async throws {
            let time = TestTime()
            let model = CameraModel(camera: camera(), time: time.source)
            await model.beginRecording()
            await waitUntil { model.stage == .composing }

            #expect(model.captured?.isVideo == true)
            #expect(model.recordingProgress == 1)
            #expect(time.now.timeIntervalSince1970 - 1_700_000_000 >= VideoPipeline.maximumDuration)
            model.discard()
        }

        @Test("Discarding deletes the clip; sending leaves it for the outbox")
        func clipOwnership() async throws {
            let model = CameraModel(camera: camera(), time: Self.still)
            await model.beginRecording()
            await model.endRecording()
            guard case .video(let discarded) = model.captured else { return }
            model.discard()
            #expect(!FileManager.default.fileExists(atPath: discarded.url.path))

            await model.beginRecording()
            await model.endRecording()
            guard case .video(let sent) = model.captured else { return }
            model.finishSending()
            #expect(model.stage == .live)
            #expect(FileManager.default.fileExists(atPath: sent.url.path))
            CaptureScratch.remove(sent.url)
        }

        @Test("The camera does not flip mid-recording")
        func noFlipWhileRecording() async {
            let camera = camera()
            let model = CameraModel(camera: camera, time: Self.still)
            await model.beginRecording()
            await model.flip()
            #expect(camera.flipCount == 0)
            model.cancelRecording()
            #expect(!model.isRecording)
            #expect(model.stage == .live)
        }
    }

    // MARK: - Compose

    @MainActor
    @Suite("Composing a clip")
    struct ComposeVideoTests {
        @Test("A clip plays once by default, cycles through the video modes, and drafts as a video")
        func videoDefaults() async throws {
            let recorded = try await clip(of: twoTone(width: 90, height: 160))
            defer { CaptureScratch.remove(recorded.url) }
            let model = ComposeModel(capture: .video(recorded))

            #expect(model.isVideo)
            #expect(model.duration == .playOnce)
            model.cycleDuration()
            #expect(model.duration == .loop)
            #expect(model.contentSize == recorded.size)
            #expect(model.includesSound, "with sound unless turned off")
            model.toggleSound()
            #expect(!model.includesSound)
            #expect(!model.draft.includesSound)
            guard case .video(let drafted) = model.draft.media else {
                Issue.record("expected a video draft")
                return
            }
            #expect(drafted == recorded)
        }

        @Test("The next clip starts looped and silent if that is how the last was left")
        func videoRemembers() async throws {
            let recorded = try await clip(of: twoTone(width: 90, height: 160))
            defer { CaptureScratch.remove(recorded.url) }
            let preferences = Preferences.inMemory()
            let first = ComposeModel(capture: .video(recorded), preferences: preferences)
            first.cycleDuration()
            first.toggleSound()

            let next = ComposeModel(capture: .video(recorded), preferences: preferences)
            #expect(next.duration == .loop)
            #expect(!next.includesSound)
            let photo = ComposeModel(image: twoTone(width: 9, height: 16), preferences: preferences)
            #expect(photo.duration == .fiveSeconds, "a clip's Loop is not a photo's duration")
        }

        @Test("The filter strip is built from the clip's first frame")
        func thumbnailsFromFirstFrame() async throws {
            let recorded = try await clip(of: twoTone(width: 90, height: 160))
            defer { CaptureScratch.remove(recorded.url) }
            let model = ComposeModel(capture: .video(recorded))
            model.prepareThumbnails()
            await model.thumbnailWork?.value
            #expect(model.filterThumbnails.count == PhotoFilter.allCases.count)
        }
    }

    // MARK: - Pipeline

    @MainActor
    @Suite("Video pipeline", .serialized)
    struct VideoPipelineTests {
        @Test("Encodes HEVC, under the budget, with the caption burned into every frame")
        func encodesWithCaption() async throws {
            let recorded = try await clip(of: twoTone())
            defer { CaptureScratch.remove(recorded.url) }
            // A bar at the very top, where the picture is pure red: the bar's
            // black backing is what shows it was drawn.
            let caption = OverlayCompositor.Caption(
                text: "hello", placement: OverlayCompositor.Placement(x: 0.5, y: 0.05)
            )
            let data = try await VideoPipeline.encode(recorded, filter: .none, captions: [caption])
            #expect(data.count <= VideoPipeline.byteBudget)

            let url = CaptureScratch.newURL(pathExtension: "mp4")
            defer { CaptureScratch.remove(url) }
            try data.write(to: url)
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let formats = try await track.load(.formatDescriptions)
            #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)

            let frame = try await firstFrame(of: data)
            #expect(frame.height > frame.width, "still portrait")
            let underCaption = colour(of: frame, x: 0.02, y: 0.05)
            let clear = colour(of: frame, x: 0.02, y: 0.25)
            #expect(clear.r > 200, "the picture itself is red there")
            #expect(underCaption.r < clear.r - 60, "the bar darkened what is under it")
        }

        /// A portrait recording is stored landscape with a transform. However
        /// AVFoundation hands the frames over, what comes out must be upright.
        @Test("A clip stored sideways comes out the right way up")
        func uprightsASidewaysClip() async throws {
            let (stored, transform) = sideways(twoTone())
            let recorded = try await clip(of: stored, transform: transform)
            defer { CaptureScratch.remove(recorded.url) }
            #expect(recorded.size.height > recorded.size.width, "the clip reports its upright shape")

            let data = try await VideoPipeline.encode(recorded, filter: .none, captions: [])
            let frame = try await firstFrame(of: data)
            #expect(frame.height > frame.width)
            let top = colour(of: frame, x: 0.5, y: 0.2)
            let bottom = colour(of: frame, x: 0.5, y: 0.8)
            #expect(top.r > 180 && top.b < 80, "red at the top")
            #expect(bottom.b > 180 && bottom.r < 80, "blue at the bottom")
        }

        @Test("Sound is kept, or left out of the file entirely")
        func soundTrack() async throws {
            let recorded = try await clip(of: twoTone(), duration: 1, withTone: true)
            defer { CaptureScratch.remove(recorded.url) }
            #expect(try await !AVURLAsset(url: recorded.url).loadTracks(withMediaType: .audio).isEmpty)

            func audioTracks(_ data: Data) async throws -> Int {
                let url = CaptureScratch.newURL(pathExtension: "mp4")
                defer { CaptureScratch.remove(url) }
                try data.write(to: url)
                return try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
            }
            let withSound = try await VideoPipeline.encode(recorded, filter: .none, captions: [])
            let without = try await VideoPipeline.encode(recorded, filter: .none, captions: [], includesSound: false)
            #expect(try await audioTracks(withSound) == 1)
            #expect(try await audioTracks(without) == 0, "not silenced — absent")
        }

        @Test("The look goes on per frame")
        func appliesFilter() async throws {
            let recorded = try await clip(of: twoTone())
            defer { CaptureScratch.remove(recorded.url) }
            let data = try await VideoPipeline.encode(recorded, filter: .mono, captions: [])
            let top = colour(of: try await firstFrame(of: data), x: 0.5, y: 0.2)
            #expect(abs(top.r - top.b) < 20, "mono takes the colour out")
        }

        @Test("Sizes stay even and inside the rung")
        func scaling() {
            #expect(VideoPipeline.scaled(CGSize(width: 1080, height: 1920), longEdge: 1920) == CGSize(width: 1080, height: 1920))
            #expect(VideoPipeline.scaled(CGSize(width: 1080, height: 1920), longEdge: 1280) == CGSize(width: 720, height: 1280))
            #expect(VideoPipeline.scaled(CGSize(width: 91, height: 161), longEdge: 1920) == CGSize(width: 92, height: 162))
        }
    }

    // MARK: - Outbox

    @MainActor
    @Suite("Sending a clip", .serialized)
    struct OutboxVideoTests {
        @Test("A clip is sent as HEVC video, and its file is deleted once encoded")
        func sendsVideo() async throws {
            let recorded = try await clip(of: twoTone(width: 180, height: 320))
            let api = FakeInstantAPI()
            let recipient = DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
            api.keysByUser[9] = [InstantDeviceKeyDTO(
                id: 1, deviceId: recipient.deviceId, publicKey: recipient.publicKeyBase64, createdAt: nil
            )]
            let outbox = Outbox(api: api) { _ in }
            outbox.send(
                InstantDraft(media: .video(recorded), filter: .none, captions: [], duration: .loop),
                to: [InstantRecipient(userId: 9, name: "Ana")],
                from: 1
            )
            await waitUntil(timeout: .seconds(30)) { !api.sentPayloads.isEmpty }

            #expect(api.sentMediaTypes == [VideoPipeline.mediaType])
            #expect(api.sentPayloads.first?.2 == .loop)
            #expect(!FileManager.default.fileExists(atPath: recorded.url.path))

            // And it opens, to an MP4, on the device it was sealed to.
            let payload = try #require(api.sentPayloads.first)
            let header = try #require(api.sentHeaders.first)
            let envelope = try #require(payload.3.first)
            let opened = try InstantCrypto.open(
                ciphertext: payload.0,
                instant: .init(
                    mediaIv: header.mediaIv, ephemeralPubKey: header.ephemeralPubKey, senderId: 1,
                    envelopeWrappedKey: envelope.wrappedKey, envelopeWrapIv: envelope.wrapIv
                ),
                device: recipient
            )
            #expect(opened.count > 8 && String(decoding: opened[4..<8], as: UTF8.self) == "ftyp")
        }
    }

    // MARK: - Viewing

    @MainActor
    @Suite("Viewing a clip", .serialized)
    struct VideoViewerTests {
        private func sealedClip(
            durationMode: InstantDurationMode
        ) async throws -> (InstantDelivery, Data, DeviceIdentity, Data) {
            let identity = DeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                backing: .software(P256.KeyAgreement.PrivateKey())
            )
            let recorded = try await clip(of: twoTone(width: 180, height: 320))
            defer { CaptureScratch.remove(recorded.url) }
            let media = try await VideoPipeline.encode(recorded, filter: .none, captions: [])
            let sealed = try InstantCrypto.seal(
                media: media, senderUserId: 2,
                devices: [.init(id: 1, deviceId: identity.deviceId, publicKey: identity.publicKeyBase64)]
            )
            let delivery = InstantDelivery(
                id: "v1", senderId: 2, senderName: "Ana", senderThemeKey: "rose",
                senderProfilePictureUrl: nil, mediaType: VideoPipeline.mediaType,
                mediaIv: sealed.mediaIv, ephemeralPubKey: sealed.ephemeralPubKey,
                byteSize: sealed.ciphertext.count, durationMode: durationMode,
                createdAt: "2026-01-01T00:00:00.000Z", expiresAt: "2026-01-02T00:00:00.000Z",
                envelope: InstantKeyEnvelope(
                    wrappedKey: sealed.envelopes[0].wrappedKey, wrapIv: sealed.envelopes[0].wrapIv
                )
            )
            return (delivery, sealed.ciphertext, identity, media)
        }

        @Test("Play once shows a ring, plays, and closes at the end")
        func playOnce() async throws {
            let (delivery, ciphertext, device, media) = try await sealedClip(durationMode: .playOnce)
            let api = FakeInstantAPI()
            api.mediaResult = .success(ciphertext)
            let stub = StubVideoPlayback()
            var handed: Data?
            let model = ViewerModel(
                instant: delivery, api: api, device: device, time: TestTime().source,
                sensitivity: FixedSensitivity(sensitive: false),
                makeVideoPlayer: { data, loops in
                    handed = data
                    #expect(!loops)
                    return stub
                }
            )
            await model.start()

            #expect(handed == media, "the decrypted bytes, as encoded")
            #expect(model.phase == .showing)
            #expect(model.image == nil)
            #expect(model.showsCountdown)
            #expect(!model.staysOpen)
            #expect(stub.isPlaying)
            await model.receiptDelivery?.value
            #expect(api.viewedIds == ["v1"])

            stub.advance(to: 0.5)
            #expect(abs(model.progress - 0.5) < 0.001)
            stub.advance(to: 1)
            #expect(model.isFinished)
            #expect(stub.isStopped)
            #expect(model.video == nil)
        }

        @Test("A loop keeps going until it is closed")
        func loops() async throws {
            let (delivery, ciphertext, device, _) = try await sealedClip(durationMode: .loop)
            let api = FakeInstantAPI()
            api.mediaResult = .success(ciphertext)
            let stub = StubVideoPlayback()
            let model = ViewerModel(
                instant: delivery, api: api, device: device, time: TestTime().source,
                sensitivity: FixedSensitivity(sensitive: false),
                makeVideoPlayer: { _, loops in
                    #expect(loops)
                    return stub
                }
            )
            await model.start()
            #expect(!model.showsCountdown)
            #expect(model.staysOpen)
            stub.advance(to: 1)
            #expect(!model.isFinished)
        }

        @Test("A report sheet holds it, the speaker toggles, and a flagged clip waits")
        func pauseMuteConceal() async throws {
            let (delivery, ciphertext, device, _) = try await sealedClip(durationMode: .playOnce)
            let api = FakeInstantAPI()
            api.mediaResult = .success(ciphertext)
            let stub = StubVideoPlayback(still: twoTone(width: 9, height: 16))
            let preferences = Preferences.inMemory()
            let model = ViewerModel(
                instant: delivery, api: api, device: device, time: TestTime().source,
                sensitivity: FixedSensitivity(sensitive: false),
                preferences: preferences,
                makeVideoPlayer: { _, _ in stub }
            )
            await model.start()
            model.pause()
            #expect(!stub.isPlaying)
            model.resume()
            #expect(stub.isPlaying)
            #expect(model.isMuted && stub.isMuted)
            model.toggleMute()
            #expect(!model.isMuted && !stub.isMuted)
            #expect(await model.reportableImage() != nil)

            let unmuted = StubVideoPlayback(still: twoTone(width: 9, height: 16))
            let next = ViewerModel(
                instant: delivery, api: api, device: device, time: TestTime().source,
                sensitivity: FixedSensitivity(sensitive: false),
                preferences: preferences,
                makeVideoPlayer: { _, _ in unmuted }
            )
            await next.start()
            #expect(!next.isMuted && !unmuted.isMuted, "the speaker stays up for the next clip")

            let flagged = StubVideoPlayback(still: twoTone(width: 9, height: 16))
            let concealedAPI = FakeInstantAPI()
            concealedAPI.mediaResult = .success(ciphertext)
            let concealed = ViewerModel(
                instant: delivery, api: concealedAPI, device: device, time: TestTime().source,
                sensitivity: FixedSensitivity(sensitive: true),
                makeVideoPlayer: { _, _ in flagged }
            )
            await concealed.start()
            #expect(concealed.isConcealed)
            #expect(!flagged.isPlaying)
            #expect(concealedAPI.viewedIds.isEmpty, "not seen until revealed")
            await concealed.reveal()
            #expect(flagged.isPlaying)
            await concealed.receiptDelivery?.value
            #expect(concealedAPI.viewedIds == ["v1"])
        }

        /// The real player, fed from memory through the resource loader. If the
        /// loader answered wrongly the asset would have no duration and no frames.
        @Test("Decrypted bytes play from memory")
        func playsFromMemory() async throws {
            let (_, _, _, media) = try await sealedClip(durationMode: .playOnce)
            let playback = AVVideoPlayback(data: media, loops: false)
            defer { playback.stop() }
            let frame = try #require(await playback.frame(at: 0.5))
            #expect(frame.size.height > frame.size.width)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: CaptureScratch.directory.path))
            _ = await playback.frame(at: 0)
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: CaptureScratch.directory.path))
            #expect(after.isSubset(of: before), "nothing written for playback")
        }
    }
}

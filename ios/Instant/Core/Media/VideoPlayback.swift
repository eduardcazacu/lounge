#if canImport(UIKit)
import AVFoundation
import Foundation
import UIKit

/// A received clip, playing — behind a protocol so the viewer's rules (once
/// means close at the end, a report sheet holds it, leaving the app ends it)
/// are tested without a player.
@MainActor
public protocol VideoPlaying: AnyObject {
    /// What the viewer's layer draws.
    var player: AVPlayer { get }
    var isMuted: Bool { get set }
    /// How far through, 0 to 1. Called on every frame or so while playing.
    var onProgress: (@MainActor (Double) -> Void)? { get set }
    /// The end of a clip that does not loop.
    var onEnded: (@MainActor () -> Void)? { get set }
    /// Once, when frames first actually move — the moment the timings call
    /// a clip open, which `play()` returning is not.
    var onPlaying: (@MainActor () -> Void)? { get set }
    func play()
    func pause()
    /// For good: the player lets go of the clip.
    func stop()
    /// A still, a fraction of the way through — the sensitivity check's input,
    /// and what a report can attach, since the evidence endpoint takes images.
    func frame(at fraction: Double) async -> UIImage?
    /// The still on screen right now.
    func currentFrame() async -> UIImage?
}

/// Plays decrypted bytes from memory.
///
/// Never from a file. A photo is decoded from `Data` and never written
/// anywhere, and `wiki/decisions.md` leans on that — the inbox cache is safe to
/// keep because nothing it points at is on disk. AVFoundation will only play a
/// URL, so the URL is a made-up scheme, and `InMemoryAssetLoader` answers it
/// out of the plaintext this object holds.
@MainActor
public final class AVVideoPlayback: VideoPlaying {
    public let player: AVPlayer
    public var onProgress: (@MainActor (Double) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    public var onPlaying: (@MainActor () -> Void)?

    private let asset: AVURLAsset
    /// Held here because the resource loader holds its delegate weakly.
    private let loader: InMemoryAssetLoader
    private let looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playingObserver: NSKeyValueObservation?
    private static let loaderQueue = DispatchQueue(label: "instant.video.loader")

    public var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    public init(data: Data, loops: Bool) {
        loader = InMemoryAssetLoader(data: data, contentType: AVFileType.mp4.rawValue)
        asset = AVURLAsset(url: URL(string: "\(InMemoryAssetLoader.scheme)://instant/clip.mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: Self.loaderQueue)
        let item = AVPlayerItem(asset: asset)

        if loops {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            looper = nil
            player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnded?() }
            }
        }
        // Muted until the speaker is tapped: the viewer opens on a tap in a
        // list, which is not the same as asking for sound. The audio session
        // is left alone. The camera's session keeps running under the inbox
        // with its microphone attached, and a category without recording in it
        // would cut the microphone off (`CameraController.configureAudioSession`).
        player.isMuted = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let duration = self.player.currentItem?.duration,
                      duration.isNumeric, duration.seconds > 0
                else { return }
                self.onProgress?(min(1, max(0, time.seconds / duration.seconds)))
            }
        }
        // `@Sendable` so it is not inferred to be main-actor isolated: KVO calls
        // it on whichever thread the player changed on.
        playingObserver = player.observe(\.timeControlStatus) { @Sendable [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in
                guard let self, let onPlaying = self.onPlaying else { return }
                self.onPlaying = nil
                onPlaying()
            }
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        looper?.disableLooping()
        player.replaceCurrentItem(with: nil)
        playingObserver = nil
        onProgress = nil
        onEnded = nil
        onPlaying = nil
    }

    public func frame(at fraction: Double) async -> UIImage? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return await still(at: CMTimeMultiplyByFloat64(duration, multiplier: min(1, max(0, fraction))))
    }

    public func currentFrame() async -> UIImage? {
        await still(at: player.currentTime())
    }

    private func still(at time: CMTime) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Answers every request for the made-up URL out of one buffer.
///
/// Immutable after init, so safe on the loader's queue.
final class InMemoryAssetLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let scheme = "instant-memory"

    private let data: Data
    private let contentType: String

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            let start = Int(request.currentOffset != 0 ? request.currentOffset : request.requestedOffset)
            guard start >= 0, start <= data.count else {
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
                return true
            }
            let length = request.requestsAllDataToEndOfResource
                ? data.count - start
                : min(request.requestedLength, data.count - start)
            request.respond(with: data.subdata(in: start..<(start + length)))
        }
        loadingRequest.finishLoading()
        return true
    }
}

/// Stands in for a player: remembers what it was told, and lets a test say
/// when the clip reached its end.
@MainActor
public final class StubVideoPlayback: VideoPlaying {
    public let player = AVPlayer()
    public var isMuted = true
    public var onProgress: (@MainActor (Double) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    public var onPlaying: (@MainActor () -> Void)?
    public private(set) var isPlaying = false
    public private(set) var isStopped = false
    public var still: UIImage?

    public init(still: UIImage? = nil) {
        self.still = still
    }

    public func play() { isPlaying = true }
    public func pause() { isPlaying = false }
    public func stop() {
        isPlaying = false
        isStopped = true
    }
    public func frame(at fraction: Double) async -> UIImage? { still }
    public func currentFrame() async -> UIImage? { still }

    /// Drives the clip as if it had played this far.
    public func advance(to fraction: Double) {
        onProgress?(fraction)
        if fraction >= 1 { onEnded?() }
    }
}
#endif

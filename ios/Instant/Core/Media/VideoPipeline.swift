#if canImport(UIKit)
import AVFoundation
import CoreImage
import Foundation
import UIKit
import VideoToolbox

/// Filters, draws on and compresses a recorded clip — the video counterpart of
/// `ImagePipeline.encode` plus `OverlayCompositor.composite`.
///
/// **HEVC, not H.264.** About 40% smaller at the same quality, which is the
/// difference between 1080×1920 fitting under the send endpoint's 3 MiB
/// ceiling at a bitrate that looks like video and not fitting. The cost is the
/// browsers that cannot decode it — Firefox, and some Linux and Android builds
/// — which is why the web viewer asks `canPlayType` before it spends the
/// one-shot fetch. See `wiki/decisions.md`.
///
/// **SDR, forced.** An iPhone will happily record HLG, and a browser shows HLG
/// as a washed-out grey picture with no error. The composition renders in
/// BT.709 and the writer tags BT.709, whatever the camera chose.
public enum VideoPipeline {
    public enum PipelineError: Error, Equatable {
        case noVideoTrack
        case readFailed
        case writeFailed
        case tooLarge
    }

    /// What `createInstantInput.mediaType` says. The codec string rides along
    /// so the web viewer's playability check is driven by the instant rather
    /// than by a guess: HEVC Main, 8-bit, level 4.1 — which covers 1080×1920
    /// at 30 fps.
    public static let mediaType = #"video/mp4; codecs="hvc1.1.6.L123.B0""#

    /// Where a frame's film grain comes from.
    ///
    /// A recording gets a new grain every frame, which is what film does. A
    /// wiggle must not: its four viewpoints are shown over and over, and
    /// grain that changed every frame would boil away on a picture that is
    /// otherwise still, and would cost the encoder a fortune in bits for
    /// noise nobody asked for. So each viewpoint keeps one grain, the same in
    /// every loop — `ParallaxRenderer.viewIndex(atFrame:)` says which.
    public enum GrainSeeding: Sendable, Equatable {
        case perFrame
        case perViewpoint
    }

    /// The longest a clip can be, which is also where the recording stops
    /// itself.
    public static let maximumDuration: Double = 5

    /// `MAX_INSTANT_BYTES` in `backend/src/route/instant.ts`, less the 16-byte
    /// GCM tag and a margin for the container's own overhead varying.
    public static let byteBudget = 3 * 1024 * 1024 - 96 * 1024

    /// Tried in order until one fits. Almost every 5-second clip fits on the
    /// first: 3 Mbps for five seconds is under 2 MB. The rest are for a scene
    /// the encoder finds expensive — foliage, water, confetti — which can
    /// overshoot an average bitrate by a lot.
    public struct Rung: Equatable, Sendable {
        public let videoBitRate: Int
        public let longEdge: CGFloat
    }

    public static let ladder: [Rung] = [
        Rung(videoBitRate: 3_000_000, longEdge: 1920),
        Rung(videoBitRate: 2_000_000, longEdge: 1920),
        Rung(videoBitRate: 1_500_000, longEdge: 1280),
    ]

    static let audioBitRate = 96_000
    static let frameRate: Int32 = 30

    /// The finished MP4's bytes. Deletes nothing: the caller owns the clip,
    /// and a send to several people encodes it once and needs it until then.
    public static func encode(
        _ clip: RecordedClip,
        filter: PhotoFilter,
        strokes: [OverlayCompositor.Stroke] = [],
        captions: [OverlayCompositor.Caption],
        includesSound: Bool = true,
        grain: GrainSeeding = .perFrame
    ) async throws -> Data {
        let asset = AVURLAsset(url: clip.url)
        let composition = try await videoComposition(
            for: asset,
            filter: filter,
            overlay: OverlayCompositor.overlay(size: clip.size, strokes: strokes, captions: captions),
            grain: grain
        )

        for rung in ladder {
            let output = CaptureScratch.newURL(pathExtension: "mp4")
            defer { CaptureScratch.remove(output) }
            let transcode = Transcode(
                asset: asset,
                composition: composition,
                outputURL: output,
                size: scaled(clip.size, longEdge: rung.longEdge),
                videoBitRate: rung.videoBitRate,
                includesSound: includesSound
            )
            do {
                try await transcode.run()
            } catch {
                // Once more after a moment. The hardware encoder is shared
                // with the rest of the system and can be briefly unavailable —
                // the camera handing it back, another app encoding — which
                // AVFoundation reports as an unknown -11800.
                CaptureScratch.remove(output)
                try await Task.sleep(for: .milliseconds(300))
                try await transcode.run()
            }
            let data = try Data(contentsOf: output)
            if data.count <= byteBudget { return data }
        }
        // Past the last rung and still over. Sending it would only be refused
        // by the server with a 400, so say so here instead.
        throw PipelineError.tooLarge
    }

    /// The per-frame recipe — upright, the look, then the drawing and the
    /// captions on top — shared by the compose screen's player and the
    /// export, so what was previewed is what is sent. `overlay` is nil for
    /// the preview, whose captions are live SwiftUI views.
    public static func videoComposition(
        for asset: AVAsset,
        filter: PhotoFilter,
        overlay: UIImage? = nil,
        grain: GrainSeeding = .perFrame
    ) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let turned = natural.applying(transform)
        let upright = CGSize(width: abs(turned.width), height: abs(turned.height))
        let orientation = Self.orientation(for: transform)
        let overlayImage = overlay?.cgImage.map { CIImage(cgImage: $0) }

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset
        ) { request in
            let frame = Self.uprighted(request.sourceImage, orientation: orientation, size: upright)
            var image = filter.apply(to: frame, grain: Self.grainSeed(at: request.compositionTime, grain: grain))
            if let overlayImage {
                image = overlayImage.composited(over: image)
            }
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: upright)), context: nil)
        }
        composition.renderSize = upright
        composition.frameDuration = CMTime(value: 1, timescale: frameRate)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    /// Which grain a frame gets: its own, or its viewpoint's.
    static func grainSeed(at time: CMTime, grain: GrainSeeding) -> Int {
        let frame = Int((time.seconds * Double(frameRate)).rounded())
        switch grain {
        case .perFrame: return frame
        case .perViewpoint: return ParallaxRenderer.viewIndex(atFrame: frame)
        }
    }

    /// Turns a frame upright if it is not already.
    ///
    /// Whether the filtering handler is handed frames with the track's
    /// transform applied is not something to depend on: a recording made with
    /// a rotation angle is stored landscape with a transform saying so, and a
    /// frame that arrives sideways composites the captions sideways. So the
    /// frame's own shape decides — one that does not match the upright size is
    /// turned by the transform, and one that does is left alone.
    static func uprighted(_ image: CIImage, orientation: CGImagePropertyOrientation, size: CGSize) -> CIImage {
        let extent = image.extent
        let matches = abs(extent.width - size.width) < 1 && abs(extent.height - size.height) < 1
        let turned = matches ? image : image.oriented(orientation)
        let origin = turned.extent.origin
        return turned.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// The EXIF orientation a track's preferred transform amounts to.
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }

    /// Even dimensions: HEVC encodes in 2×2 chroma blocks, and an odd edge is
    /// refused by the writer rather than rounded.
    static func scaled(_ size: CGSize, longEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        let scale = longest > longEdge && longest > 0 ? longEdge / longest : 1
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

/// One pass of reader → writer.
///
/// A class, and `@unchecked Sendable`, because AVFoundation's reader and
/// writer are neither and both are driven from a serial queue of their own:
/// everything below touches them from that queue or before it starts.
private final class Transcode: @unchecked Sendable {
    private let asset: AVAsset
    private let composition: AVVideoComposition
    private let outputURL: URL
    private let size: CGSize
    private let videoBitRate: Int
    /// False leaves the audio track out of the file altogether, rather than
    /// writing silence.
    private let includesSound: Bool
    private let queue = DispatchQueue(label: "instant.video.transcode")

    init(
        asset: AVAsset,
        composition: AVVideoComposition,
        outputURL: URL,
        size: CGSize,
        videoBitRate: Int,
        includesSound: Bool
    ) {
        self.asset = asset
        self.composition = composition
        self.outputURL = outputURL
        self.size = size
        self.videoBitRate = videoBitRate
        self.includesSound = includesSound
    }

    func run() async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTrack = includesSound ? try await asset.loadTracks(withMediaType: .audio).first : nil
        guard !videoTracks.isEmpty else { throw VideoPipeline.PipelineError.noVideoTrack }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoPipeline.PipelineError.readFailed }
        reader.add(videoOutput)

        // Mono at 44.1 kHz: it is one phone microphone, and the reader does
        // the conversion so the writer is handed exactly what it encodes.
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // The index up front. Nothing streams an instant — it arrives whole —
        // but a player handed a blob starts sooner when it need not seek to
        // the end first.
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: VideoPipeline.frameRate,
                AVVideoMaxKeyFrameIntervalKey: VideoPipeline.frameRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoPipeline.PipelineError.writeFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: VideoPipeline.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else { throw VideoPipeline.PipelineError.readFailed }
        guard writer.startWriting() else { throw VideoPipeline.PipelineError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        // Both at once, never one after the other: the writer interleaves, so
        // it stops asking for video once video is far enough ahead of audio,
        // and a pump waiting for audio that has not started never finishes.
        var pumps = [Pump(output: videoOutput, input: videoInput, queue: queue)]
        if let audioOutput, let audioInput {
            pumps.append(Pump(output: audioOutput, input: audioInput, queue: queue))
        }
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { await pump.run() }
            }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw VideoPipeline.PipelineError.readFailed
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoPipeline.PipelineError.writeFailed }
    }
}

/// Copies one track across until the reader runs dry, then marks the input
/// finished. Resumes exactly once, however many times the writer comes back
/// asking for more. `@unchecked Sendable` for the same reason `Transcode` is:
/// the output and the input are only touched on the transcode's queue.
private final class Pump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private var done = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, queue: DispatchQueue) {
        self.output = output
        self.input = input
        self.queue = queue
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        done = true
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
#endif

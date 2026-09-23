#if canImport(UIKit)
import AVFoundation
import Foundation
import UIKit

/// A video as the camera left it: a file in the capture scratch directory, not
/// yet filtered, drawn on, encoded or sealed.
///
/// It is a file rather than bytes because AVFoundation records to and reads
/// from files — there is no in-memory path through `AVCaptureMovieFileOutput`
/// or `AVAssetReader`. That makes a clip the one form of an instant that sits
/// on the sender's disk, and `CaptureScratch` is what keeps that brief.
public struct RecordedClip: Equatable, Sendable {
    public let url: URL
    /// Seconds, as recorded.
    public let duration: Double
    /// Upright pixel size — the shape the compose screen lays out and the
    /// overlay is drawn at, which for a portrait recording is the track's
    /// natural size turned by its transform.
    public let size: CGSize

    public init(url: URL, duration: Double, size: CGSize) {
        self.url = url
        self.duration = duration
        self.size = size
    }

    /// Reads the duration and the upright size off the file itself, rather
    /// than trusting what the recorder said it asked for.
    public static func load(from url: URL) async throws -> RecordedClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoPipeline.PipelineError.noVideoTrack
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let turned = natural.applying(transform)
        return RecordedClip(
            url: url,
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            size: CGSize(width: abs(turned.width), height: abs(turned.height))
        )
    }
}

/// Where clips live between the shutter and the seal.
///
/// The photo path never writes a photo anywhere; video cannot avoid it, so the
/// next best thing is one directory that is emptied at every launch and every
/// sign-out, and a clip deleted the moment it has been encoded or discarded.
/// Readable after first unlock rather than only while unlocked, because the
/// encode runs after the compose screen closes and the phone may be locked by
/// then — the same protection the outbox's sealed sends have.
public enum CaptureScratch {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("instant-capture", isDirectory: true)
    }

    /// A fresh path in the directory, which is created if it has to be.
    public static func newURL(pathExtension: String) -> URL {
        let directory = directory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathExtension(pathExtension)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Everything, whatever it was for. Anything left here from an earlier run
    /// belonged to a send that was killed before it was sealed, and a sealed
    /// send never needs its clip again.
    public static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
/// Writes a still picture out as a short clip.
///
/// The stand-in camera's recording, and the tests' source of clips: a real
/// movie file, decoded by the same AVFoundation paths a recording is, so what
/// runs under test is the pipeline and the player rather than a mock of them.
/// `transform` lets a test store the frames sideways with a transform saying
/// so, which is how a portrait recording actually arrives, and `withTone` gives
/// it a sound track, which is how a test finds out whether sound was kept.
public enum StillClipWriter {
    public static func write(
        _ image: UIImage,
        duration: Double,
        framesPerSecond: Int32 = 30,
        transform: CGAffineTransform = .identity,
        withTone: Bool = false,
        to url: URL
    ) async throws {
        let upright = ImagePipeline.normalizingOrientation(image)
        guard let cgImage = upright.cgImage else { throw VideoPipeline.PipelineError.writeFailed }
        // The picture's size in points, as `ImagePipeline` measures a photo —
        // not its pixels. A frame drawn by `UIGraphicsImageRenderer` is at the
        // screen's scale, and at 3× the stand-in camera's 1080×1920 frame was a
        // 3240×5760 clip that took the Simulator most of a minute to write.
        let width = max(2, Int(upright.size.width.rounded()) / 2 * 2)
        let height = max(2, Int(upright.size.height.rounded()) / 2 * 2)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        let audioInput: AVAssetWriterInput? = withTone
            ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            : nil
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
        }
        guard writer.startWriting() else { throw VideoPipeline.PipelineError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        if let audioInput {
            for buffer in try toneBuffers(duration: duration) {
                while !audioInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard audioInput.append(buffer) else { throw VideoPipeline.PipelineError.writeFailed }
            }
            audioInput.markAsFinished()
        }

        guard let buffer = pixelBuffer(cgImage, width: width, height: height) else {
            throw VideoPipeline.PipelineError.writeFailed
        }
        let frames = max(1, Int((duration * Double(framesPerSecond)).rounded()))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw VideoPipeline.PipelineError.writeFailed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoPipeline.PipelineError.writeFailed }
    }

    /// A 440 Hz sine, mono, in tenth-of-a-second buffers.
    private static func toneBuffers(duration: Double) throws -> [CMSampleBuffer] {
        let rate = 44_100.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true
        ) else { throw VideoPipeline.PipelineError.writeFailed }
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { throw VideoPipeline.PipelineError.writeFailed }

        let chunk = Int(rate / 10)
        let total = Int(rate * duration)
        var buffers: [CMSampleBuffer] = []
        var start = 0
        while start < total {
            let count = min(chunk, total - start)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = pcm.int16ChannelData?[0]
            else { throw VideoPipeline.PipelineError.writeFailed }
            pcm.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let t = Double(start + index) / rate
                samples[index] = Int16(sin(2 * .pi * 440 * t) * 8_000)
            }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                decodeTimeStamp: .invalid
            )
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: formatDescription, sampleCount: count,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
            )
            guard let sample, CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: 0, bufferList: pcm.audioBufferList
            ) == noErr else { throw VideoPipeline.PipelineError.writeFailed }
            buffers.append(sample)
            start += count
        }
        return buffers
    }

    static func pixelBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
#endif

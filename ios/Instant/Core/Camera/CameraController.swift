#if canImport(UIKit)
import AVFoundation
import Foundation
import UIKit

/// The capture surface, behind a protocol.
///
/// Two reasons it is not a concrete type: the Simulator has no camera at all, so
/// the UI needs a photo-library path that is not an afterthought; and UI tests
/// need a fixed frame to assert against.
@MainActor
public protocol CameraControlling: AnyObject {
    var isAvailable: Bool { get }
    var position: AVCaptureDevice.Position { get }
    var isFlashOn: Bool { get set }
    var session: AVCaptureSession? { get }

    /// True once the session is running and the preview has something to show.
    /// Until then the preview layer is blank, and revealing it produces the
    /// black flash this exists to avoid.
    var isPreviewReady: Bool { get }

    /// Current magnification, and what this camera will actually accept.
    var zoomFactor: CGFloat { get }
    var zoomRange: ClosedRange<CGFloat> { get }

    func start() async
    func stop()
    func flip() async
    func setZoom(_ factor: CGFloat)
    func capture() async throws -> UIImage
}

public extension CameraControlling {
    var canZoom: Bool { zoomRange.upperBound > zoomRange.lowerBound }

    /// Clamping lives here so it can be checked without a camera attached —
    /// which, on the Simulator, is always.
    static func clampedZoom(_ factor: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        guard factor.isFinite else { return range.lowerBound }
        return min(max(factor, range.lowerBound), range.upperBound)
    }
}

public enum CameraError: Error, Equatable {
    case unavailable
    case denied
    case captureFailed
}

@MainActor
public final class CameraController: NSObject, CameraControlling {
    public private(set) var position: AVCaptureDevice.Position = .front
    public var isFlashOn = false
    public private(set) var session: AVCaptureSession?
    public private(set) var isPreviewReady = false
    public private(set) var zoomFactor: CGFloat = 1

    /// Past a certain point digital zoom is just interpolation, and on a phone
    /// camera that arrives well before the hardware's stated maximum.
    static let maximumUsefulZoom: CGFloat = 8

    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var pending: CheckedContinuation<UIImage, Error>?

    public override init() {
        super.init()
    }

    public var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    public func start() async {
        guard isAvailable else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }

        let session = self.session ?? AVCaptureSession()
        self.session = session

        if input == nil {
            session.beginConfiguration()
            // 1080p rather than `.photo`, for two reasons that happen to be the
            // same decision. It is natively 16:9, which is the shape Instant
            // sends; and it keeps the capture off the full-sensor still path,
            // whose multi-frame fusion is most of the delay between pressing
            // the shutter and having a photo. The pipeline downscales to 1080
            // wide regardless, so nothing survives to the wire that this gives up.
            session.sessionPreset = .hd1920x1080
            if let device = Self.camera(at: position),
               let deviceInput = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
                input = deviceInput
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
                configureForResponsiveness()
            }
            session.commitConfiguration()
        }

        guard !session.isRunning else {
            isPreviewReady = true
            return
        }
        await withCheckedContinuation { continuation in
            // startRunning blocks; keeping it off the main actor stops the
            // camera page from hitching as it appears.
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                continuation.resume()
            }
        }
        // startRunning returns once the session is live, which is within a frame
        // or so of the first buffer reaching the preview layer. The fade the
        // view applies covers that remainder.
        isPreviewReady = session.isRunning
    }

    /// The rest of the shutter-lag story, and it has to run while the session is
    /// being configured.
    ///
    /// Zero shutter lag is the one that matters: the output keeps a ring buffer
    /// of recent frames and returns the one from the moment of the press
    /// instead of the next one the sensor produces. Without it the photo is of
    /// whatever happened a beat *after* the button went down, which is the
    /// complaint. The other two let a second shot begin while the first is
    /// still being processed, so the shutter never feels locked.
    private func configureForResponsiveness() {
        if output.isZeroShutterLagSupported {
            output.isZeroShutterLagEnabled = true
        }
        // Order matters: responsive capture requires zero shutter lag, and fast
        // capture prioritization requires responsive capture.
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
        }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = true
        }
        // `.quality` would put the fusion pipeline back; `.speed` would take
        // zero shutter lag away with it. Balanced is the one that keeps both.
        output.maxPhotoQualityPrioritization = .balanced
    }

    public func stop() {
        isPreviewReady = false
        guard let session, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    public var zoomRange: ClosedRange<CGFloat> {
        guard let device = input?.device else { return 1...1 }
        let lower = device.minAvailableVideoZoomFactor
        let upper = min(device.maxAvailableVideoZoomFactor, Self.maximumUsefulZoom)
        // A camera that cannot zoom reports an empty span rather than an
        // invalid range.
        return upper > lower ? lower...upper : lower...lower
    }

    public func setZoom(_ factor: CGFloat) {
        guard let device = input?.device else { return }
        let clamped = Self.clampedZoom(factor, to: zoomRange)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        // Zoom is a property of the capture device, so the photo comes out
        // magnified without the capture path knowing anything about it.
        zoomFactor = clamped
    }

    /// Returns only once the other camera is worth looking at, which is a
    /// little after the session says it is configured.
    ///
    /// Swapping the input leaves the outgoing camera's last frame sitting in
    /// the preview layer, and the new connection redraws it with the *new*
    /// camera's mirroring — so for a moment the screen shows the old picture,
    /// flipped. What follows it is no better: the first frames off a camera
    /// that just woke up arrive dark and ramp as auto-exposure settles. The
    /// view freezes the preview across this call; the job here is to not end
    /// it early.
    public func flip() async {
        let target: AVCaptureDevice.Position = position == .front ? .back : .front
        guard let session, let current = input else {
            position = target
            return
        }
        guard let device = Self.camera(at: target),
              let replacement = try? AVCaptureDeviceInput(device: device) else { return }
        // The swap itself goes off the main actor for two reasons:
        // begin/commitConfiguration is slow enough to hitch the camera screen,
        // and yielding here is what lets the view put its freeze up before the
        // swap shows through.
        let swapped: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                session.beginConfiguration()
                session.removeInput(current)
                let accepted = session.canAddInput(replacement)
                // Put the camera we had back if it is not, and stay on it:
                // reporting a position the session is not actually on would
                // mirror the preview the wrong way.
                session.addInput(accepted ? replacement : current)
                session.commitConfiguration()
                continuation.resume(returning: accepted)
            }
        }
        guard swapped else { return }
        input = replacement
        position = target
        // The front and back cameras have different limits, so carrying a zoom
        // across the flip would either clamp oddly or jump.
        zoomFactor = 1
        setZoom(1)
        await Self.settle(device)
    }

    /// Waits out the new camera's first frames.
    ///
    /// A floor, because exposure is reported as settled before there has been
    /// anything to expose; then as long as the device admits to still
    /// adjusting, up to a ceiling — a camera pointed at something hard to meter
    /// can adjust for a while, and freezing the preview until it is happy would
    /// read as the flip having failed.
    private static func settle(_ device: AVCaptureDevice) async {
        try? await Task.sleep(for: .milliseconds(180))
        let deadline = Date().addingTimeInterval(0.25)
        while device.isAdjustingExposure, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    public func capture() async throws -> UIImage {
        guard session != nil, input != nil else { throw CameraError.unavailable }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .balanced
        if output.supportedFlashModes.contains(.on) {
            settings.flashMode = isFlashOn ? .on : .off
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Not isolated, so the flip can look a device up from the queue it
    /// reconfigures the session on.
    private nonisolated static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor [weak self] in
            guard let self, let continuation = pending else { return }
            pending = nil
            if let data, let image = UIImage(data: data) {
                // Selfies are mirrored on screen; capturing them unmirrored
                // makes any caption the user positioned read backwards relative
                // to what they framed.
                continuation.resume(
                    returning: Self.upright(image, mirrored: position == .front)
                )
            } else {
                continuation.resume(throwing: CameraError.captureFailed)
            }
        }
    }

    /// Bakes the EXIF orientation in, and the mirror with it.
    ///
    /// One render pass rather than two: a selfie used to be normalized and then
    /// flipped, which is a full-frame redraw of a frame nobody ever saw.
    static func upright(_ image: UIImage, mirrored: Bool) -> UIImage {
        guard mirrored else { return ImagePipeline.normalizingOrientation(image) }
        let size = image.size
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            // `draw(in:)` applies the orientation itself, so this single pass is
            // both the normalization and the flip.
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Stands in for the camera where there is not one: the Simulator, and UI tests.
@MainActor
public final class StubCameraController: CameraControlling {
    public var isAvailable: Bool
    public private(set) var position: AVCaptureDevice.Position = .front
    public var isFlashOn = false
    public var session: AVCaptureSession? { nil }
    public private(set) var isPreviewReady = false
    public private(set) var flipCount = 0
    /// Runs inside `flip()`, while the swap is notionally in flight. The real
    /// controller does not return until the new camera is producing frames; a
    /// test needs the same window to look at.
    public var duringFlip: (@MainActor () -> Void)?
    public private(set) var zoomFactor: CGFloat = 1
    public var zoomRange: ClosedRange<CGFloat>
    private let frame: UIImage

    public init(
        isAvailable: Bool = true,
        zoomRange: ClosedRange<CGFloat> = 1...8,
        frame: UIImage
    ) {
        self.isAvailable = isAvailable
        self.zoomRange = zoomRange
        self.frame = frame
    }

    public func start() async { isPreviewReady = true }
    public func stop() { isPreviewReady = false }

    public func setZoom(_ factor: CGFloat) {
        zoomFactor = Self.clampedZoom(factor, to: zoomRange)
    }

    public func flip() async {
        flipCount += 1
        duringFlip?()
        await Task.yield()
        position = position == .front ? .back : .front
        zoomFactor = 1
    }

    public func capture() async throws -> UIImage {
        guard isAvailable else { throw CameraError.unavailable }
        return frame
    }
}
#endif

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
            session.sessionPreset = .photo
            if let device = camera(at: position),
               let deviceInput = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
                input = deviceInput
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
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

    public func flip() async {
        position = position == .front ? .back : .front
        guard let session, let current = input else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if let device = camera(at: position),
           let replacement = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(replacement) {
            session.addInput(replacement)
            input = replacement
        } else {
            session.addInput(current)
        }
        session.commitConfiguration()
        // The front and back cameras have different limits, so carrying a zoom
        // across the flip would either clamp oddly or jump.
        zoomFactor = 1
        setZoom(1)
    }

    public func capture() async throws -> UIImage {
        guard session != nil, input != nil else { throw CameraError.unavailable }

        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(.on) {
            settings.flashMode = isFlashOn ? .on : .off
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let mirror = photo.metadata[kCGImagePropertyOrientation as String] != nil
        _ = mirror
        let data = photo.fileDataRepresentation()
        Task { @MainActor [weak self] in
            guard let self, let continuation = pending else { return }
            pending = nil
            if let data, let image = UIImage(data: data) {
                // Selfies are mirrored on screen; capturing them unmirrored
                // makes any caption the user positioned read backwards relative
                // to what they framed.
                let corrected = position == .front ? Self.mirrored(image) : image
                continuation.resume(returning: ImagePipeline.normalizingOrientation(corrected))
            } else {
                continuation.resume(throwing: CameraError.captureFailed)
            }
        }
    }

    static func mirrored(_ image: UIImage) -> UIImage {
        let upright = ImagePipeline.normalizingOrientation(image)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: upright.size, format: format).image { context in
            context.cgContext.translateBy(x: upright.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            upright.draw(in: CGRect(origin: .zero, size: upright.size))
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
        position = position == .front ? .back : .front
        zoomFactor = 1
    }

    public func capture() async throws -> UIImage {
        guard isAvailable else { throw CameraError.unavailable }
        return frame
    }
}
#endif

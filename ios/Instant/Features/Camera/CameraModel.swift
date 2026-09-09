#if canImport(UIKit)
import Foundation
import Observation
import UIKit

@MainActor
@Observable
public final class CameraModel {
    public enum Stage: Equatable {
        case live
        /// A frame is captured and waiting to be composed.
        case composing
    }

    public private(set) var stage: Stage = .live
    public private(set) var captured: UIImage?
    public private(set) var isCapturing = false
    public private(set) var errorMessage: String?
    /// True while a pinch is in flight, so the indicator can show and then go.
    public private(set) var isZooming = false

    /// Where the zoom was when the current pinch began. A pinch reports
    /// magnification relative to its own start, so without this every gesture
    /// would snap back to 1x before growing.
    private var zoomAtGestureStart: CGFloat = 1

    public let camera: CameraControlling

    public init(camera: CameraControlling) {
        self.camera = camera
    }

    /// The Simulator has no camera at all, and a device can refuse permission.
    /// Either way the answer is the photo library rather than a dead screen.
    public var needsLibraryFallback: Bool { !camera.isAvailable }

    public func start() async {
        await camera.start()
    }

    public func stop() {
        camera.stop()
    }

    public func flip() async {
        await camera.flip()
    }

    // MARK: - Zoom

    public var zoomFactor: CGFloat { camera.zoomFactor }
    public var canZoom: Bool { camera.canZoom }

    /// e.g. "2.4x". Hidden at rest so it does not sit on the photo permanently.
    public var zoomLabel: String {
        String(format: "%.1f×", camera.zoomFactor)
    }

    public func beginZoom() {
        zoomAtGestureStart = camera.zoomFactor
        isZooming = true
    }

    public func updateZoom(magnification: CGFloat) {
        guard isZooming else { return }
        camera.setZoom(zoomAtGestureStart * magnification)
    }

    public func endZoom() {
        isZooming = false
        zoomAtGestureStart = camera.zoomFactor
    }

    public func toggleFlash() {
        camera.isFlashOn.toggle()
    }

    public func shoot() async {
        guard !isCapturing else { return }
        isCapturing = true
        errorMessage = nil
        defer { isCapturing = false }
        do {
            adopt(try await camera.capture())
        } catch {
            errorMessage = "Could not take that photo."
        }
    }

    /// Shared by the shutter and the library picker so both land in one place.
    public func adopt(_ image: UIImage) {
        captured = ImagePipeline.normalizingOrientation(image)
        stage = .composing
    }

    public func discard() {
        captured = nil
        stage = .live
    }
}
#endif

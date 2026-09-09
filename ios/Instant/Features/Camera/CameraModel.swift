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

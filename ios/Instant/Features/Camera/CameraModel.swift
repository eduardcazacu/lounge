#if canImport(UIKit)
import AVFoundation
import Foundation
import Observation
import UIKit

/// What the shutter produced: a tap's photo or a hold's clip.
public enum Capture: Equatable, Sendable {
    case photo(UIImage)
    case video(RecordedClip)

    public var isVideo: Bool {
        if case .video = self { true } else { false }
    }
}

@MainActor
@Observable
public final class CameraModel {
    public enum Stage: Equatable {
        case live
        /// A frame is captured and waiting to be composed.
        case composing
    }

    public private(set) var stage: Stage = .live
    public private(set) var captured: Capture?
    public private(set) var isCapturing = false

    /// From the recording actually starting until its file is finished.
    public private(set) var isRecording = false
    /// 0 to 1 across the five seconds a clip may run — the ring that fills
    /// around the shutter.
    public private(set) var recordingProgress: Double = 0
    /// A hold was recognised and the recorder is still getting ready. A
    /// release in this window is kept, and ends the recording the moment it
    /// has begun: the finger is not asked to wait for the microphone.
    private var isStartingRecording = false
    private var stopRequested = false
    /// The app left while the recorder was still starting. The start cannot be
    /// called back, so it is undone the moment it returns.
    private var cancelRequested = false
    private var recordingClock: Task<Void, Never>?
    private let time: TimeSource

    // Mirrored from the capture device rather than read through to it.
    //
    // `CameraControlling` is a plain protocol over an AVFoundation object, so
    // SwiftUI registers no dependency on anything reached via `model.camera.…`
    // — the view only refreshed when some *other* observable property happened
    // to change, which is why the flash button appeared stuck until a photo was
    // taken. These are the state the view actually reads.
    public private(set) var isPreviewReady = false
    public private(set) var isFlashOn = false
    public private(set) var position: AVCaptureDevice.Position = .front
    public private(set) var zoomFactor: CGFloat = 1
    public private(set) var canZoom = false
    public private(set) var errorMessage: String?
    /// True while a pinch is in flight, so the indicator can show and then go.
    public private(set) var isZooming = false

    /// True from the tap on the flip button until the other camera is actually
    /// producing frames worth showing. The view holds the last frame of the old
    /// camera for the length of it, because what the preview layer shows in
    /// between belongs to neither camera: the outgoing one's last frame,
    /// redrawn mirrored the wrong way, and then the incoming one's first few
    /// frames arriving dark.
    public private(set) var isSwitching = false

    /// Where the zoom was when the current pinch began. A pinch reports
    /// magnification relative to its own start, so without this every gesture
    /// would snap back to 1x before growing.
    private var zoomAtGestureStart: CGFloat = 1

    public let camera: CameraControlling

    public init(camera: CameraControlling, time: TimeSource = .live) {
        self.camera = camera
        self.time = time
        syncFromCamera()
    }

    /// Pulls the device's current state onto the model, which is the only thing
    /// the view observes.
    private func syncFromCamera() {
        isPreviewReady = camera.isPreviewReady
        isFlashOn = camera.isFlashOn
        position = camera.position
        zoomFactor = camera.zoomFactor
        canZoom = camera.canZoom
    }

    /// The Simulator has no camera at all, and a device can refuse permission.
    /// Either way the answer is the photo library rather than a dead screen.
    public var needsLibraryFallback: Bool { !camera.isAvailable }

    public func start() async {
        await camera.start()
        // Zoom limits are only knowable once a device is attached.
        syncFromCamera()
    }

    public func stop() {
        cancelRecording()
        camera.stop()
        syncFromCamera()
    }

    public func flip() async {
        // The recorder is writing one camera's frames to one file; changing
        // camera under it is not a flip, it is a broken clip.
        guard !isSwitching, !isRecording, !isStartingRecording else { return }
        isSwitching = true
        // Set before the await, so the freeze is on screen before the session
        // swaps under it.
        await camera.flip()
        isSwitching = false
        syncFromCamera()
    }

    /// Which camera is live, in words. The flip button carries it as its
    /// accessibility value — the icon is the same either way round, so without
    /// this the control announces itself identically in both states.
    public var positionLabel: String {
        position == .front ? "Front" : "Back"
    }

    // MARK: - Zoom

    /// e.g. "2.4x". Hidden at rest so it does not sit on the photo permanently.
    public var zoomLabel: String {
        String(format: "%.1f×", zoomFactor)
    }

    public func beginZoom() {
        zoomAtGestureStart = camera.zoomFactor
        isZooming = true
    }

    public func updateZoom(magnification: CGFloat) {
        guard isZooming else { return }
        camera.setZoom(zoomAtGestureStart * magnification)
        // Published on every step, so the indicator tracks the pinch rather
        // than jumping when the gesture ends.
        zoomFactor = camera.zoomFactor
    }

    public func endZoom() {
        isZooming = false
        zoomAtGestureStart = camera.zoomFactor
        zoomFactor = camera.zoomFactor
    }

    public func toggleFlash() {
        camera.isFlashOn.toggle()
        isFlashOn = camera.isFlashOn
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

    // MARK: - Recording

    /// The hold was recognised. Starts the recorder, and the clock that stops
    /// it at the limit.
    public func beginRecording() async {
        guard !isCapturing, !isRecording, !isStartingRecording, !isSwitching else { return }
        isStartingRecording = true
        stopRequested = false
        cancelRequested = false
        isCapturing = true
        errorMessage = nil
        do {
            try await camera.startRecording()
        } catch CameraError.askedForMicrophone {
            // The prompt has had the moment; the next hold records.
            isStartingRecording = false
            isCapturing = false
            return
        } catch {
            isStartingRecording = false
            isCapturing = false
            errorMessage = "Could not record that video."
            return
        }
        if cancelRequested {
            cancelRequested = false
            camera.cancelRecording()
            return
        }
        isStartingRecording = false
        isRecording = true
        recordingProgress = 0
        runRecordingClock()
        if stopRequested { await endRecording() }
    }

    /// The finger lifted, or the five seconds ran out — whichever came first.
    public func endRecording() async {
        if isStartingRecording {
            stopRequested = true
            return
        }
        guard isRecording else { return }
        isRecording = false
        recordingClock?.cancel()
        recordingClock = nil
        defer { isCapturing = false }
        do {
            let clip = try await camera.stopRecording()
            recordingProgress = 1
            captured = .video(clip)
            stage = .composing
        } catch {
            recordingProgress = 0
            errorMessage = "Could not record that video."
        }
    }

    /// The app is leaving mid-recording. What was recorded is not kept: a clip
    /// cut short by the app going away is not one anybody chose to send.
    public func cancelRecording() {
        guard isRecording || isStartingRecording else { return }
        if isStartingRecording { cancelRequested = true }
        recordingClock?.cancel()
        recordingClock = nil
        camera.cancelRecording()
        isRecording = false
        isStartingRecording = false
        isCapturing = false
        recordingProgress = 0
    }

    private func runRecordingClock() {
        let startedAt = time.now()
        let limit = VideoPipeline.maximumDuration
        recordingClock = Task { [weak self, time] in
            while !Task.isCancelled {
                try? await time.sleep(.milliseconds(33))
                guard !Task.isCancelled, let self else { return }
                let elapsed = time.now().timeIntervalSince(startedAt)
                recordingProgress = min(1, elapsed / limit)
                if elapsed >= limit {
                    // Let go of itself first. `endRecording` cancels the
                    // clock, and this is the clock: cancelled, the stop it is
                    // about to await would be cancelled with it, and the clip
                    // held to the limit would be lost.
                    recordingClock = nil
                    await endRecording()
                    return
                }
            }
        }
    }

    /// Shared by the shutter and the library picker so both land in one place —
    /// including the 16:9 crop, so what compose shows and what goes on the wire
    /// is the shape the viewport framed, whichever of the two the photo came
    /// from.
    public func adopt(_ image: UIImage) {
        captured = .photo(ImagePipeline.croppedToFrame(image))
        stage = .composing
    }

    /// The cross on the compose screen. A clip is deleted here, because
    /// nothing else will ever read it.
    public func discard() {
        if case .video(let clip) = captured {
            CaptureScratch.remove(clip.url)
        }
        reset()
    }

    /// Back to the camera after a send. The clip is left alone: the outbox
    /// has it now, and deletes it once it has been encoded.
    public func finishSending() {
        reset()
    }

    private func reset() {
        captured = nil
        recordingProgress = 0
        stage = .live
    }
}
#endif

#if canImport(UIKit)
import AVFoundation
import PhotosUI
import SwiftUI

/// The home screen. A rounded 16:9 viewport on black with the controls inside
/// it: flip and flash top-right, shutter at the bottom, and the account button
/// facing them from the opposite corner, drawn by `MainPager` — Snapchat's
/// arrangement, because it puts the one action that matters under the thumb and
/// everything else out of the way.
struct CameraScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: CameraModel?
    @State private var libraryItem: PhotosPickerItem?
    /// Drives the shutter. Lives in the view rather than the model because it
    /// is a statement about the press, not about the capture: it goes up on the
    /// tap, which is the moment the photo is of, and comes down when there is a
    /// photo to look at.
    @State private var shutterOpacity: Double = 0
    /// The shutter is down and has not yet been held long enough to record.
    @State private var holdTimer: Task<Void, Never>?
    /// The shutter was held long enough; lifting it ends the recording.
    @State private var isHolding = false

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            if let model {
                if let captured = model.captured, model.stage == .composing {
                    ComposeScreen(
                        capture: captured,
                        onDiscard: { model.discard() },
                        onSent: { model.finishSending() }
                    )
                        .transition(.opacity)
                        // The pinned account button is drawn over this screen,
                        // and lands on the discard cross. It steps aside for as
                        // long as there is a photo to decide about.
                        .onAppear {
                            environment.isComposing = true
                            revealCapture()
                        }
                        .onDisappear { environment.isComposing = false }
                } else {
                    live(model)
                }
            }

            // Above both screens, because it has to outlast the handover from
            // one to the other: anything visible in between is the live camera
            // still moving under a photo that has already been taken.
            shutterCover
        }
        .task {
            if model == nil { model = CameraModel(camera: environment.makeCamera()) }
            await model?.start()
        }
        // Deliberately no `.onDisappear { stop() }`: swiping to the inbox and
        // back should not cost a session restart, which is most of a second of
        // black. The session is only torn down when the app actually leaves the
        // foreground, which iOS requires anyway.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                holdTimer?.cancel()
                holdTimer = nil
                isHolding = false
                model?.stop()
                // A capture interrupted by the app leaving cannot be allowed to
                // leave the frame black on the way back.
                shutterOpacity = 0
            case .active:
                Task { await model?.start() }
            default:
                break
            }
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    model?.adopt(image)
                }
                libraryItem = nil
            }
        }
    }

    @ViewBuilder
    private func live(_ model: CameraModel) -> some View {
        ZStack {
            viewport(model)

            ViewportOverlay {
                VStack {
                    // Out of the way while recording: the frame is the whole
                    // point for those five seconds, and a flip or a flash
                    // mid-clip is not something the recorder can take.
                    toolRail(model)
                        .opacity(model.isRecording ? 0 : 1)
                        .allowsHitTesting(!model.isRecording)
                    if let recipient = environment.aimedAt, !model.isRecording {
                        aimChip(recipient)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.isZooming, model.canZoom {
                        zoomIndicator(model)
                            .padding(.bottom, 18)
                            .transition(.opacity)
                    }
                    bottomBar(model)
                }
                .animation(.easeOut(duration: 0.15), value: model.isZooming)
                .animation(.easeOut(duration: 0.2), value: environment.aimedAt)
                .animation(.easeOut(duration: 0.2), value: model.isRecording)
            }
        }
    }

    /// The framing rectangle, and the whole point of it is that it is the same
    /// 16:9 the capture delivers. It used to run edge to edge while the photo
    /// underneath was 3:4, so the review screen showed a picture nobody had
    /// framed. Sizing it by the shape of the photo costs a black band at each
    /// end on a tall phone, which is where the chrome now sits anyway.
    private func viewport(_ model: CameraModel) -> some View {
        ZStack {
            // The placeholder sits underneath for the whole of startup, so the
            // preview fades in over something rather than over black.
            cameraPlaceholder(model)

            if let session = model.camera.session {
                CameraPreview(
                    session: session,
                    mirrored: model.position == .front,
                    isSwitching: model.isSwitching
                )
                .opacity(model.isPreviewReady ? 1 : 0)
                .animation(.easeOut(duration: 0.28), value: model.isPreviewReady)
                // Pinch anywhere on the frame. Zoom is a property of the
                // capture device, so the photo comes out magnified too.
                .gesture(
                    MagnifyGesture(minimumScaleDelta: 0)
                        .onChanged { value in
                            if !model.isZooming { model.beginZoom() }
                            model.updateZoom(magnification: value.magnification)
                        }
                        .onEnded { _ in model.endZoom() }
                )
                .accessibilityIdentifier("camera.preview")
            }
        }
        .aspectRatio(InstantStyle.viewportAspectRatio, contentMode: .fit)
        .clipShape(InstantStyle.viewportShape)
        // Double-tap anywhere on the frame to turn the camera round — the
        // gesture every camera app has, and the one that does not cost a reach
        // to the far corner. On the frame rather than on the preview so it
        // still answers on a device with no camera attached, and a count of two
        // so it cannot be triggered by the single taps the frame ignores.
        .onTapGesture(count: 2) {
            Task { await model.flip() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// Who the shot is already for, shown while framing rather than only on the
    /// send button — an aim set a few taps ago in the inbox must not be a
    /// surprise discovered after the photo is taken. The cross drops it.
    private func aimChip(_ recipient: InstantRecipient) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 11, weight: .bold))
            // The identifier sits on the text rather than the row: a plain
            // `HStack` is no accessibility element, and the cross has to stay a
            // button of its own rather than being combined into a label.
            Text("Sending to \(recipient.name)")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("camera.aim")
            Button {
                environment.clearAim()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera.aim.clear")
            .accessibilityLabel("Stop sending to \(recipient.name)")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private func zoomIndicator(_ model: CameraModel) -> some View {
        Text(model.zoomLabel)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .accessibilityIdentifier("camera.zoom")
    }

    /// Sits under the preview for the whole of startup, so the camera fades in
    /// over something rather than over black — and stays visible on a device
    /// that has no camera at all.
    @ViewBuilder
    private func cameraPlaceholder(_ model: CameraModel) -> some View {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            if model.needsLibraryFallback {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                    Text("No camera here")
                        .font(.headline)
                    Text("Pick a photo from your library instead.")
                        .font(.footnote)
                        .foregroundStyle(InstantStyle.secondaryText)
                }
                .foregroundStyle(InstantStyle.primaryText)
            }
        }
    }

    /// A right-hand rail, the same one the compose screen has: the tools for the
    /// frame run down the side, and the account button `MainPager` draws sits
    /// opposite the top of it. The two screens are the same surface with
    /// different tools on it, so the tools belong in the same place.
    private func toolRail(_ model: CameraModel) -> some View {
        HStack {
            Spacer()

            VStack(spacing: 12) {
                CircleIconButton(
                    systemName: model.isFlashOn ? "bolt.fill" : "bolt.slash.fill",
                    isOn: model.isFlashOn
                ) {
                    model.toggleFlash()
                }
                .accessibilityIdentifier("camera.flash")

                CircleIconButton(systemName: "arrow.triangle.2.circlepath.camera") {
                    Task { await model.flip() }
                }
                .accessibilityIdentifier("camera.flip")
                .accessibilityLabel("Flip camera")
                .accessibilityValue(model.positionLabel)
            }
        }
    }

    private func bottomBar(_ model: CameraModel) -> some View {
        HStack {
            inboxPill

            Spacer()

            if model.needsLibraryFallback {
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    ShutterButton(enabled: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("camera.shutter")
            } else {
                shutter(model)
            }

            Spacer()

            // Balances the chat button on the left. The streak count lives with
            // the person it belongs to, on the conversation row.
            Color.clear.frame(width: 48, height: 48)
        }
    }

    /// A tap takes a photo; a hold records, for as long as the finger stays
    /// down or five seconds, whichever is shorter.
    ///
    /// One gesture decides both, rather than a tap and a long press competing:
    /// a gesture that outranks a tap still waits on it, and the recording would
    /// start when the finger lifted (see `wiki/gotchas.md`). Down starts a short
    /// timer; lifting before it fires is a photo, and the timer firing is the
    /// hold.
    private func shutter(_ model: CameraModel) -> some View {
        ShutterButton(
            enabled: !model.isCapturing || model.isRecording,
            isRecording: model.isRecording,
            progress: model.recordingProgress
        )
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdTimer == nil, !isHolding, !model.isCapturing else { return }
                    holdTimer = Task { @MainActor in
                        try? await Task.sleep(for: Self.holdThreshold)
                        guard !Task.isCancelled else { return }
                        holdTimer = nil
                        isHolding = true
                        await model.beginRecording()
                    }
                }
                .onEnded { _ in
                    if let timer = holdTimer {
                        // Lifted before it became a hold: a photo.
                        timer.cancel()
                        holdTimer = nil
                        Task { await capture(model) }
                    } else if isHolding {
                        isHolding = false
                        Task { await model.endRecording() }
                    }
                }
        )
        // When the recorder has actually started, not when the hold was
        // recognised: the tap is the signal that what follows is on the clip.
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording) { _, recording in recording }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Take photo")
        .accessibilityValue(model.isRecording ? "recording" : "")
        .accessibilityIdentifier("camera.shutter")
        // A tap for a photo, and an action of its own for a video, since a
        // hold of a particular length is not something VoiceOver can do.
        .accessibilityAction {
            if model.isRecording {
                Task { await model.endRecording() }
            } else {
                Task { await capture(model) }
            }
        }
        .accessibilityAction(named: "Record video") {
            Task { await model.beginRecording() }
        }
    }

    /// Long enough that a quick press is never read as a hold, short enough
    /// that a deliberate one does not feel ignored.
    static let holdThreshold: Duration = .milliseconds(300)

    /// Black over the frame, from the press until there is a photo to look at.
    ///
    /// It is not a blink. A blink ends on a timer, and whatever is left between
    /// the end of it and the photo appearing is the live camera still moving
    /// under a frame that was captured a moment ago — which reads as the
    /// shutter having missed. This stays up for exactly that window instead, so
    /// the last thing the viewfinder does is stop.
    private var shutterCover: some View {
        Color.black
            .aspectRatio(InstantStyle.viewportAspectRatio, contentMode: .fit)
            .clipShape(InstantStyle.viewportShape)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .opacity(shutterOpacity)
            .allowsHitTesting(false)
    }

    /// Covers the frame, takes the photo, and — if the capture failed — gives
    /// the frame back. The successful path is uncovered by the compose screen
    /// appearing, which is the moment the photo is actually on screen.
    private func capture(_ model: CameraModel) async {
        // Fast enough to read as a cut rather than a fade; not instant, which
        // on a bright frame reads as a dropped frame.
        withAnimation(.easeOut(duration: 0.04)) { shutterOpacity = 1 }
        await model.shoot()
        if model.stage != .composing {
            revealCapture()
        }
    }

    private func revealCapture() {
        withAnimation(.easeIn(duration: 0.12)) { shutterOpacity = 0 }
    }

    private var inboxPill: some View {
        Button {
            environment.showsInbox = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.black.opacity(0.35)))

                if environment.store.unreadCount > 0 {
                    Text("\(environment.store.unreadCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(InstantStyle.unread))
                        .offset(x: 4, y: -2)
                        .accessibilityIdentifier("camera.unreadBadge")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("camera.inbox")
    }

}

struct ShutterButton: View {
    let enabled: Bool
    var isRecording = false
    /// 0 to 1 through the five seconds a clip may run.
    var progress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(enabled ? 1 : 0.4), lineWidth: 5)
                .frame(width: 78, height: 78)
            // The time left, as the ring filling clockwise from the top: a
            // clip that stops itself has to show that it is going to.
            Circle()
                .inset(by: 2.5)
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(InstantStyle.recording, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 78, height: 78)
                .opacity(isRecording ? 1 : 0)
            Circle()
                .fill(isRecording ? InstantStyle.recording : Color.white.opacity(enabled ? 0.15 : 0.05))
                .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
        }
        .scaleEffect(isRecording ? 1.18 : 1)
        .animation(.easeOut(duration: 0.18), value: isRecording)
    }
}

/// `AVCaptureVideoPreviewLayer` has no SwiftUI equivalent.
///
/// The layer resizes with the view rather than being told an aspect ratio: the
/// web client had a bug where a guessed ratio letterboxed the preview and,
/// worse, made the captured frame a different shape from what was on screen.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    /// True while the session is swapping cameras, which is the window the
    /// preview layer has nothing honest to show.
    let isSwitching: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// The outgoing camera's last frame, held over the live layer for the
        /// length of a flip.
        private var held: UIView?

        /// Freezes what is on screen right now.
        ///
        /// `snapshotView` rather than rendering the layer: `render(in:)` draws
        /// nothing at all for a video layer, and a snapshot view is a reference
        /// to content the compositor already has rather than a full-frame
        /// redraw on the main thread. `afterScreenUpdates: false` because the
        /// frame wanted here is the one already on screen — the next update is
        /// the one being hidden.
        func hold() {
            guard held == nil, bounds.width > 0, bounds.height > 0 else { return }
            let cover = UIView(frame: bounds)
            cover.isUserInteractionEnabled = false
            // Behind the snapshot rather than instead of it: a snapshot taken
            // before the view has ever been drawn comes back empty, and this
            // still covers the swap.
            cover.backgroundColor = .black
            if let snapshot = snapshotView(afterScreenUpdates: false) {
                snapshot.frame = cover.bounds
                snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.addSubview(snapshot)
            }
            addSubview(cover)
            held = cover
        }

        /// Cross-fades back to the live camera. Short, because by the time this
        /// is called the new camera is already exposed and steady — the fade is
        /// only there to keep the cut from registering as one.
        func release() {
            guard let cover = held else { return }
            held = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState) {
                cover.alpha = 0
            } completion: { _ in
                cover.removeFromSuperview()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            held?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // Before the mirroring below: once that changes, the stale frame in the
        // layer is already being drawn the wrong way round.
        if isSwitching {
            view.hold()
        }
        view.previewLayer.session = session
        // Selfies read as mirrored on screen, the way a mirror does; the capture
        // path un-mirrors to match.
        view.previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        view.previewLayer.connection?.isVideoMirrored = mirrored
        if !isSwitching {
            view.release()
        }
    }
}
#endif

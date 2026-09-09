#if canImport(UIKit)
import AVFoundation
import PhotosUI
import SwiftUI

/// The home screen. Full-bleed preview, profile top-left, flip and flash
/// top-right, shutter at the bottom — Snapchat's arrangement, because it puts
/// the one action that matters under the thumb and everything else out of the way.
struct CameraScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: CameraModel?
    @State private var showsSettings = false
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            if let model {
                if let captured = model.captured, model.stage == .composing {
                    ComposeScreen(image: captured) { model.discard() }
                        .transition(.opacity)
                } else {
                    live(model)
                }
            }
        }
        .task {
            if model == nil { model = CameraModel(camera: environment.makeCamera()) }
            await model?.start()
        }
        .onDisappear { model?.stop() }
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
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
            if let session = model.camera.session {
                CameraPreview(session: session, mirrored: model.position == .front)
                    .ignoresSafeArea()
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
            } else {
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
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

            VStack {
                topBar(model)
                Spacer()
                if model.isZooming, model.canZoom {
                    zoomIndicator(model)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
                bottomBar(model)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .animation(.easeOut(duration: 0.15), value: model.isZooming)
        }
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

    private func topBar(_ model: CameraModel) -> some View {
        HStack {
            Button { showsSettings = true } label: {
                // The signed-in account, not a placeholder: their picture if
                // they have one, their initials if not.
                AvatarView(
                    name: environment.account?.name ?? "",
                    themeKey: environment.account?.themeKey ?? ThemePalette.defaultKey,
                    url: environment.account?.profilePictureUrl,
                    size: 40
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera.profile")

            Spacer()

            HStack(spacing: 12) {
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
                Button {
                    Task { await model.shoot() }
                } label: {
                    ShutterButton(enabled: !model.isCapturing)
                }
                .buttonStyle(.plain)
                .disabled(model.isCapturing)
                .accessibilityIdentifier("camera.shutter")
            }

            Spacer()

            // Balances the chat button on the left. The streak count lives with
            // the person it belongs to, on the conversation row.
            Color.clear.frame(width: 48, height: 48)
        }
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

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(enabled ? 1 : 0.4), lineWidth: 5)
                .frame(width: 78, height: 78)
            Circle()
                .fill(Color.white.opacity(enabled ? 0.15 : 0.05))
                .frame(width: 62, height: 62)
        }
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

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
        // Selfies read as mirrored on screen, the way a mirror does; the capture
        // path un-mirrors to match.
        view.previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        view.previewLayer.connection?.isVideoMirrored = mirrored
    }
}
#endif

#if canImport(UIKit)
import AVFoundation
import SwiftUI

/// Full-screen, black, one photo, one countdown. Tap anywhere to close.
struct ViewerScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: ViewerModel
    let onClose: () -> Void
    /// Called when the sender was blocked from here, after the viewer closes.
    var onBlocked: (Int) -> Void = { _ in }

    @State private var report: ReportModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .loading:
                ProgressView().tint(.white)

            case .showing:
                // Not drawn at all while concealed: a video layer is
                // composited outside SwiftUI and does not take the blur a
                // photo does, so hiding it is the only way to hide it.
                if let video = model.video, !model.isConcealed {
                    PlayerLayerView(player: video.player)
                        .ignoresSafeArea()
                        .accessibilityElement()
                        .accessibilityLabel("A video from \(model.instant.displayName)")
                        .accessibilityIdentifier("viewer.video")
                } else if model.video != nil {
                    Color.black.ignoresSafeArea()
                        .accessibilityIdentifier("viewer.concealedVideo")
                }
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .blur(radius: model.isConcealed ? 48 : 0, opaque: true)
                        .ignoresSafeArea()
                        .accessibilityIdentifier(model.isConcealed ? "viewer.concealedImage" : "viewer.image")
                }
                if model.isConcealed {
                    sensitiveWarning
                }

            case .gone(let text):
                notice(text, systemName: "clock.badge.xmark")
                    .accessibilityIdentifier("viewer.gone")

            case .undecryptable:
                notice(
                    "This couldn't be opened on this device. Instant keys don't leave the device that made them, so anything sent to an older install stays sealed.",
                    systemName: "lock.trianglebadge.exclamationmark"
                )
                .accessibilityIdentifier("viewer.undecryptable")

            case .failed(let text):
                notice(text, systemName: "exclamationmark.triangle")
                    .accessibilityIdentifier("viewer.failed")
            }

            VStack {
                HStack(alignment: .top) {
                    Text(model.instant.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // A photo is letterboxed, so this usually straddles its
                        // top edge. A translucent black vanished on the black
                        // half and left a dark sliver on the photo; a material
                        // reads as one capsule over both.
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)

                    Spacer()

                    if model.video != nil, model.phase == .showing, !model.isConcealed {
                        Button {
                            model.toggleMute()
                        } label: {
                            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.isMuted ? "Turn sound on" : "Turn sound off")
                        .accessibilityIdentifier("viewer.mute")
                    }

                    if model.showsCountdown {
                        CountdownRing(progress: model.progress)
                            .frame(width: 34, height: 34)
                            .accessibilityIdentifier("viewer.countdown")
                    }

                    // Always offered, whatever state the photo is in: someone
                    // who sent something that would not open is no less
                    // reportable. A Button, so it wins over the close-on-tap.
                    Button {
                        openReport()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Report \(model.instant.displayName)")
                    .accessibilityIdentifier("viewer.more")
                }
                Spacer()

                if model.staysOpen, model.phase == .showing, !model.isConcealed {
                    Text("Tap anywhere to close")
                        .font(.footnote)
                        .foregroundStyle(Color(white: 0.75))
                        .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.finish() }
        .task { await model.start() }
        .onChange(of: model.isFinished) { _, finished in
            if finished { onClose() }
        }
        .onChange(of: scenePhase) { _, phase in
            // No pausing the clock by switching apps.
            if phase != .active, model.phase == .showing { model.finish() }
        }
        .statusBarHidden()
        .sheet(item: $report, onDismiss: { model.resume() }) { report in
            ReportScreen(
                model: report,
                termsURL: environment.config.webAppURL.appendingPathComponent("terms")
            ) { blocked in
                // A reported photo is closed rather than resumed: nobody who
                // just reported something wants the rest of its countdown.
                model.finish()
                if blocked { onBlocked(model.instant.senderId) }
            }
        }
    }

    private func openReport() {
        model.pause()
        Task {
            // For a clip, the frame it was stopped on: the evidence endpoint
            // takes a picture, and that one is what prompted the report.
            let evidence = await model.reportableImage()
            report = ReportModel(
                reportedUserId: model.instant.senderId,
                reportedName: model.instant.displayName,
                instantId: model.instant.id,
                photo: evidence,
                isVideoFrame: model.isVideo,
                api: environment.moderationAPI
            )
        }
    }

    private var sensitiveWarning: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 40))
            Text(model.isVideo ? "This video may be sensitive" : "This photo may be sensitive")
                .font(.headline)
            Text("It was hidden on this device because it may contain nudity. Nothing was sent to anyone to check it.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(white: 0.8))
            HStack(spacing: 12) {
                Button("View anyway") {
                    Task { await model.reveal() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityIdentifier("viewer.reveal")

                Button("Report") { openReport() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("viewer.concealedReport")
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(36)
    }

    private func notice(_ text: String, systemName: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemName).font(.system(size: 38))
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(white: 0.85))
        .padding(36)
    }
}

/// The viewer before there is an instant to view: a notification was tapped,
/// and what it named has not been fetched yet.
///
/// Drawn as the viewer's own loading state — black, the sender's name where
/// the viewer puts it — so the instant arriving changes the least it can.
struct WaitingViewerScreen: View {
    let senderName: String?
    let onClose: () -> Void

    /// After this long the wait is worth explaining. An instant opened on
    /// another device never arrives here at all.
    static let patience: Duration = .seconds(8)
    @State private var isOverdue = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white)
                if isOverdue {
                    Text("Still looking for this instant. If it was opened on another device, it's gone.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(white: 0.85))
                        .padding(.horizontal, 36)
                        .transition(.opacity)
                }
            }
            VStack {
                HStack {
                    if let senderName {
                        Text(senderName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .environment(\.colorScheme, .dark)
                    }
                    Spacer()
                }
                Spacer()
                Text("Tap to close")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.75))
                    .padding(.bottom, 24)
                    .opacity(isOverdue ? 1 : 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .statusBarHidden()
        .accessibilityIdentifier("viewer.waiting")
        .task {
            try? await Task.sleep(for: Self.patience)
            withAnimation(.easeOut(duration: 0.2)) { isOverdue = true }
        }
    }
}

/// `AVPlayerLayer` has no SwiftUI equivalent. Aspect-fit, like the photo.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

struct CountdownRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
#endif

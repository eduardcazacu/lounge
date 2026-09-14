#if canImport(UIKit)
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

                if model.instant.durationMode == .infinite, model.phase == .showing {
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
        report = ReportModel(
            reportedUserId: model.instant.senderId,
            reportedName: model.instant.displayName,
            instantId: model.instant.id,
            photo: model.isConcealed || model.phase == .showing ? model.image : nil,
            api: environment.moderationAPI
        )
    }

    private var sensitiveWarning: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 40))
            Text("This photo may be sensitive")
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

#if canImport(UIKit)
import SwiftUI

/// Full-screen, black, one photo, one countdown. Tap anywhere to close.
struct ViewerScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: ViewerModel
    let onClose: () -> Void

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
                        .ignoresSafeArea()
                        .accessibilityIdentifier("viewer.image")
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
                        .background(Capsule().fill(Color.black.opacity(0.4)))

                    Spacer()

                    if model.showsCountdown {
                        CountdownRing(progress: model.progress)
                            .frame(width: 34, height: 34)
                            .accessibilityIdentifier("viewer.countdown")
                    }
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

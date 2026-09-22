#if canImport(UIKit)
import AVFoundation
import SwiftUI

/// The clip on the compose screen, round and round, with the chosen look.
///
/// The look is the export's own per-frame recipe
/// (`VideoPipeline.videoComposition`) with no overlay: the captions and the
/// drawing on this screen are live views above it, exactly as they are over a
/// photo. It goes through that composition even with no look chosen, so the
/// frame is turned upright here by the same code that turns it in the export —
/// a clip that previewed the right way up and was sent sideways is the one
/// thing this must not be able to do.
///
/// With sound unless the sender has turned it off, which also takes the sound
/// out of what is sent (`ComposeModel.includesSound`) — the preview plays
/// exactly what will arrive.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let filter: PhotoFilter
    let isMuted: Bool

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    @MainActor
    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var filter: PhotoFilter?
        private var loading: Task<Void, Never>?

        init() {}

        func load(_ url: URL, filter: PhotoFilter) {
            self.filter = filter
            loading?.cancel()
            loading = Task { [weak self] in
                let asset = AVURLAsset(url: url)
                let composition = try? await VideoPipeline.videoComposition(for: asset, filter: filter)
                guard let self, !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = composition
                // The looper copies its template, so a new look is a new
                // looper rather than a change to the one playing.
                looper?.disableLooping()
                player.removeAllItems()
                looper = AVPlayerLooper(player: player, templateItem: item)
                player.play()
            }
        }

        func stop() {
            loading?.cancel()
            looper?.disableLooping()
            looper = nil
            player.pause()
            player.removeAllItems()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.player.isMuted = isMuted
        context.coordinator.load(url, filter: filter)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.player.isMuted = isMuted
        if context.coordinator.filter != filter {
            context.coordinator.load(url, filter: filter)
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.stop()
    }
}
#endif

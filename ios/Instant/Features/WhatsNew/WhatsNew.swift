import Foundation

/// The notes shown once after an update.
///
/// Keyed by their own `version` rather than by the bundle's, so a release that
/// ships without notes shows nothing — it does not re-show the last ones. A
/// release with something to say replaces `current` and bumps `version` to
/// match `MARKETING_VERSION`.
public struct WhatsNew: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let symbol: String
        public let title: String
        public let detail: String
    }

    public let version: String
    public let features: [Item]
    public let fixes: [Item]

    public static let current = WhatsNew(
        version: "1.3",
        features: [
            Item(
                symbol: "rotate.3d",
                title: "Photos that wiggle",
                detail: "Tap 3D after taking a photo and it becomes a short clip rocking between four angles, the way a Nishika print does. The phone works out what is near and what is far and moves them by different amounts, so what you get has depth rather than a shake. Send it as a loop, or once."
            ),
            Item(
                symbol: "video.fill",
                title: "Send a video",
                detail: "Hold the shutter to record up to five seconds, with sound — the ring round the button shows how long you have left. Write and draw on it like a photo, then choose whether it plays once or loops. It disappears once it's been watched, just like a photo."
            ),
            Item(
                symbol: "square.and.arrow.down",
                title: "Keep a copy",
                detail: "The arrow beside Send saves the instant to your own photos, with the look, the drawing and the captions already in the pixels — a 3D one goes as its clip. Only what you made: an instant somebody sent you still disappears."
            ),
            Item(
                symbol: "slider.horizontal.3",
                title: "Your settings stick",
                detail: "How long a photo shows, whether a video loops, sound on or off, and your pen colour are remembered, so the next one starts the way you left the last."
            ),
        ],
        fixes: []
    )
}

/// Which notes this device has already shown.
///
/// Per device rather than per account: they describe the app, not anybody's
/// data. A sign-in marks the notes seen, because someone who has just
/// installed the app has nothing to compare it with. The notes are therefore
/// shown only to someone who was already signed in when the update landed.
/// 1.0 never wrote this key, so its absence alone cannot separate an upgrade
/// from a fresh install. Being signed in already is what separates them.
public struct WhatsNewTracker: Sendable {
    // UserDefaults is thread-safe but not marked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    public let notes: WhatsNew

    static let key = "instant.whatsNew.lastSeenVersion"

    public init(defaults: UserDefaults = .standard, notes: WhatsNew = .current) {
        self.defaults = defaults
        self.notes = notes
    }

    public var isDue: Bool {
        defaults.string(forKey: Self.key) != notes.version
    }

    public func markSeen() {
        defaults.set(notes.version, forKey: Self.key)
    }
}

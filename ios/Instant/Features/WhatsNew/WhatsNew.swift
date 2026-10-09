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
        version: "1.7",
        features: [
            Item(
                symbol: "slider.horizontal.3",
                title: "Pro controls",
                detail: "A new button under flip opens two more: white balance, which switches between the film look's daylight preset and the camera's own auto, and exposure, a slider that brightens or darkens by up to three stops. Double-tap the slider to put it back to zero."
            ),
            Item(
                symbol: "camera.filters",
                title: "A truer film look",
                detail: "The camera now shoots at a fixed daylight white balance, the light Portra is made for, so the film look starts from the same place every time instead of a different one each scene. Indoor light keeps its warmth, as it would on film."
            ),
            Item(
                symbol: "flame.fill",
                title: "Streaks last until the end of the day",
                detail: "A send keeps a streak alive until midnight UTC at the end of the next day, rather than for exactly 24 hours, so a photo sent at breakfast no longer has to be answered by breakfast."
            ),
            Item(
                symbol: "sparkles",
                title: "Liquid Glass",
                detail: "The buttons over the camera and your photos are glass on iOS 26."
            ),
        ],
        fixes: [
            Item(
                symbol: "bell.badge.fill",
                title: "Notifications arrive while you are away",
                detail: "An instant sent while the app was in the background could arrive without a banner or a widget update until you opened it again."
            ),
            Item(
                symbol: "bell.slash.fill",
                title: "Opened instants leave Notification Center",
                detail: "Opening an instant from your conversations now clears its notification, which used to stay behind and open onto nothing."
            ),
        ]
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

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
        version: "1.1",
        features: [
            Item(
                symbol: "paperplane.fill",
                title: "Send and keep going",
                detail: "Tapping Send takes you straight back to the camera. A pill at the bottom shows your photo on its way, and tells you once it's sent."
            ),
            Item(
                symbol: "arrow.clockwise.circle.fill",
                title: "Sends that don't get lost",
                detail: "If a photo can't be sent, tap Retry. If Instant is closed while a photo is sending, it finishes sending the next time you open the app, and a notification tells you if it hasn't gone yet."
            ),
            Item(
                symbol: "tray.full.fill",
                title: "Your inbox opens instantly",
                detail: "Opening Instant from a notification or the widget shows your conversations straight away, instead of \u{201C}No conversations yet\u{201D} while it loads."
            ),
        ],
        fixes: [
            Item(
                symbol: "square.grid.2x2.fill",
                title: "The widget updates by itself",
                detail: "It now shows a new photo when it arrives. Before, it only updated after you opened the app."
            ),
            Item(
                symbol: "bell.badge.fill",
                title: "One notification, not two",
                detail: "If you also use the Lounge in a browser, you now get each photo's notification once, on your phone."
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

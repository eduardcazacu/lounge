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
        version: "1.2",
        features: [
            Item(
                symbol: "person.2.fill",
                title: "Send to several people at once",
                detail: "In Send To, tick as many people as you like and send the photo to all of them in one go. Each of them gets their own copy, which disappears once they've seen it."
            ),
            Item(
                symbol: "person.3.fill",
                title: "Send to everyone",
                detail: "Tap All to send a photo to everyone who has Instant set up. It asks you first, so a slip of the thumb doesn't send it to the whole Lounge."
            ),
            Item(
                symbol: "textformat",
                title: "Write anywhere on a photo",
                detail: "Tap anywhere on a photo you've just taken to write on it, and tap somewhere else to add more. Long text wraps onto a new line. Tap any text to change it."
            ),
            Item(
                symbol: "character.textbox",
                title: "Two styles of text",
                detail: "Text starts on a band across the photo. While you're typing, tap the button at the top right to put it in its own box instead, which you can drag anywhere, pinch to make bigger or smaller, and turn with two fingers."
            ),
            Item(
                symbol: "trash",
                title: "Drag text away to delete it",
                detail: "Hold a piece of text and drag it onto the bin at the top of the photo."
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

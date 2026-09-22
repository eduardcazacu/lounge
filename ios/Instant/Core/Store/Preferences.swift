#if canImport(UIKit)
import Foundation

/// The choices someone makes over and over — how long a photo shows, whether
/// a clip loops, the sound, the pen's colour — kept so the next capture starts
/// where the last one left off instead of back at the defaults.
///
/// Per device rather than per account, like the update notes: they are how
/// this person holds this phone, not anybody's data, and nothing about them is
/// worth a round trip or survives being wrong for one capture.
///
/// Each value is remembered the moment it is chosen, not on send. A discarded
/// capture still says what the person wanted next time.
public final class Preferences: @unchecked Sendable {
    // UserDefaults is thread-safe but not marked Sendable; the dictionary
    // behind `inMemory()` is guarded by the lock.
    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memory: [String: String] = [:]

    enum Key {
        static let photoDuration = "instant.preferences.photoDuration"
        static let videoDuration = "instant.preferences.videoDuration"
        static let sendsSound = "instant.preferences.sendsSound"
        static let viewerMuted = "instant.preferences.viewerMuted"
        static let ink = "instant.preferences.ink"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private init(memoryOnly: Void) {
        defaults = nil
    }

    /// Remembers for as long as the object lives. The default for the models,
    /// so a test that picks red ink does not hand red ink to the next test.
    public static func inMemory() -> Preferences {
        Preferences(memoryOnly: ())
    }

    /// How long a photo shows. Photo and clip modes are two families that
    /// never mix, so each remembers its own: a Loop chosen for a clip must not
    /// become the next photo's duration, which the server would refuse.
    public var photoDuration: InstantDurationMode {
        get {
            let stored = string(Key.photoDuration).flatMap(InstantDurationMode.init(rawValue:))
            guard let stored, !stored.isVideoMode else { return .fiveSeconds }
            return stored
        }
        set {
            guard !newValue.isVideoMode else { return }
            set(newValue.rawValue, Key.photoDuration)
        }
    }

    /// Once or Loop.
    public var videoDuration: InstantDurationMode {
        get {
            let stored = string(Key.videoDuration).flatMap(InstantDurationMode.init(rawValue:))
            guard let stored, stored.isVideoMode else { return .playOnce }
            return stored
        }
        set {
            guard newValue.isVideoMode else { return }
            set(newValue.rawValue, Key.videoDuration)
        }
    }

    /// Whether a clip goes with its sound — compose's speaker.
    public var sendsSound: Bool {
        get { bool(Key.sendsSound) ?? true }
        set { set(String(newValue), Key.sendsSound) }
    }

    /// Whether a received clip opens silent — the viewer's speaker.
    public var viewerMuted: Bool {
        get { bool(Key.viewerMuted) ?? true }
        set { set(String(newValue), Key.viewerMuted) }
    }

    public var ink: OverlayCompositor.Ink {
        get { string(Key.ink).flatMap(OverlayCompositor.Ink.init(rawValue:)) ?? .white }
        set { set(newValue.rawValue, Key.ink) }
    }

    /// Stored as strings throughout, so an absent key is told apart from
    /// `false` and a value this build does not recognise falls back to the
    /// default rather than to whatever `UserDefaults` coerces it into.
    private func string(_ key: String) -> String? {
        if let defaults { return defaults.string(forKey: key) }
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }

    private func bool(_ key: String) -> Bool? {
        string(key).flatMap(Bool.init)
    }

    private func set(_ value: String, _ key: String) {
        if let defaults { defaults.set(value, forKey: key); return }
        lock.lock(); defer { lock.unlock() }
        memory[key] = value
    }
}
#endif

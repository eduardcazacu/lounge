import Foundation
import Testing
import UIKit
@testable import Instant

/// The next capture starts where the last one left off. What can go wrong is
/// quiet: a remembered value from the wrong family, or one a later build does
/// not know, turning into a duration the server refuses.
@MainActor
@Suite("Remembered compose and viewer choices")
struct PreferencesTests {
    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 9, height: 16)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 9, height: 16))
        }
    }

    @Test("Nothing chosen yet means the old defaults")
    func defaults() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(preferences.photoDuration == .fiveSeconds)
        #expect(preferences.videoDuration == .playOnce)
        #expect(preferences.sendsSound)
        #expect(preferences.viewerMuted)
        #expect(preferences.ink == .white)
    }

    @Test("Survives a relaunch, which is a new object over the same defaults")
    func persists() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = Preferences(defaults: defaults)
        first.photoDuration = .infinite
        first.videoDuration = .loop
        first.sendsSound = false
        first.viewerMuted = false
        first.ink = .pink

        let second = Preferences(defaults: defaults)
        #expect(second.photoDuration == .infinite)
        #expect(second.videoDuration == .loop)
        #expect(!second.sendsSound)
        #expect(!second.viewerMuted)
        #expect(second.ink == .pink)
    }

    @Test("A duration from the other family is refused, and so is one this build does not know")
    func durationFamilies() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(defaults: defaults)
        preferences.photoDuration = .loop
        preferences.videoDuration = .oneSecond
        #expect(preferences.photoDuration == .fiveSeconds)
        #expect(preferences.videoDuration == .playOnce)

        defaults.set("loop", forKey: Preferences.Key.photoDuration)
        defaults.set("boomerang", forKey: Preferences.Key.videoDuration)
        defaults.set("gold", forKey: Preferences.Key.ink)
        #expect(preferences.photoDuration == .fiveSeconds)
        #expect(preferences.videoDuration == .playOnce)
        #expect(preferences.ink == .white)
    }

    @Test("The next photo starts with the last photo's duration and pen")
    func composeRemembers() {
        let preferences = Preferences.inMemory()
        let first = ComposeModel(image: photo(), preferences: preferences)
        first.cycleDuration()
        first.ink = .blue
        let chosen = first.duration

        let next = ComposeModel(image: photo(), preferences: preferences)
        #expect(next.duration == chosen)
        #expect(next.ink == .blue)
    }
}

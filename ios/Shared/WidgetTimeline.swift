import Foundation
import WidgetKit

/// One frame of the widget: which contact is on screen, and where in the cycle.
public struct WaitingEntry: TimelineEntry, Equatable, Sendable {
    public let date: Date
    /// `nil` means nothing is waiting, and the widget shows the app mark.
    public let contact: InstantWidgetSnapshot.Contact?
    public let totalWaiting: Int
    public let contactCount: Int
    /// Which contact of `contactCount` this entry shows, for the dots.
    public let position: Int

    public init(
        date: Date,
        contact: InstantWidgetSnapshot.Contact?,
        totalWaiting: Int,
        contactCount: Int,
        position: Int
    ) {
        self.date = date
        self.contact = contact
        self.totalWaiting = totalWaiting
        self.contactCount = contactCount
        self.position = position
    }

    public static let placeholder = WaitingEntry(
        date: .distantPast, contact: nil, totalWaiting: 0, contactCount: 0, position: 0
    )
}

/// Builds the widget's timeline.
///
/// Lives here rather than in the extension so it can be tested: an app
/// extension's code is not reachable from the app's test bundle, and the cycling
/// rule is logic rather than presentation.
public enum WidgetTimeline {
    /// How long each contact stays on screen before the next.
    ///
    /// Cycling is done with pre-computed entries rather than by asking WidgetKit
    /// to reload. Entries are rendered on schedule and cost nothing extra;
    /// reloads come out of a daily budget.
    public static let cycleInterval: TimeInterval = 30
    /// How long one timeline keeps cycling before WidgetKit is asked for the
    /// next one.
    public static let cycleWindow: TimeInterval = 60 * 60

    /// When WidgetKit should come back for a new timeline, or `nil` for never.
    ///
    /// The snapshot only changes when the app or the Notification Service
    /// Extension writes it, and both ask for a reload when they do. A scheduled
    /// refresh re-reads the same file, and every one is charged to the widget's
    /// daily reload budget, which is only about 40 to 70. Once that is spent,
    /// WidgetKit ignores the reload the extension asks for when an instant
    /// arrives, and the widget stays stale until the app is opened: reloads
    /// from the foreground app are free. So only a cycle, which has to keep
    /// going after its last entry, asks to be called back.
    public static func nextRefresh(after entries: [WaitingEntry]) -> Date? {
        guard entries.count > 1, let last = entries.last else { return nil }
        return last.date.addingTimeInterval(cycleInterval)
    }

    public static func entries(from snapshot: InstantWidgetSnapshot, now: Date) -> [WaitingEntry] {
        let contacts = snapshot.contacts

        guard !contacts.isEmpty else {
            return [WaitingEntry(
                date: now, contact: nil, totalWaiting: 0, contactCount: 0, position: 0
            )]
        }

        // One person needs no cycle, and a timeline of identical entries would
        // only cost battery.
        guard contacts.count > 1 else {
            return [WaitingEntry(
                date: now,
                contact: contacts[0],
                totalWaiting: snapshot.totalWaiting,
                contactCount: 1,
                position: 0
            )]
        }

        // Always at least one full pass, even if the window is short.
        let steps = max(contacts.count, Int(cycleWindow / cycleInterval))
        return (0..<steps).map { step in
            WaitingEntry(
                date: now.addingTimeInterval(Double(step) * cycleInterval),
                contact: contacts[step % contacts.count],
                totalWaiting: snapshot.totalWaiting,
                contactCount: contacts.count,
                position: step % contacts.count
            )
        }
    }
}

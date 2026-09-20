import Foundation

/// How long ago something happened, in the two words a list row has space for.
///
/// `RelativeDateTimeFormatter` is the obvious tool and it is wrong at exactly
/// the end that matters: a photo sent four seconds ago comes out as "in 0
/// seconds", and the freshest receipt is the one anybody actually reads. So the
/// scale here starts at a floor of "just now" and is deliberately coarse above
/// it — nobody reading an inbox row cares about the difference between 41 and
/// 44 minutes.
///
/// Units are floored rather than rounded, so the phrase is never ahead of the
/// clock: something 119 seconds old says "1m ago", not "2m ago".
public enum RelativeTime {
    private enum Unit: Equatable {
        case justNow
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    private static func unit(since date: Date, now: Date) -> Unit {
        // A clock that disagrees with the server's by a few seconds must not
        // produce a receipt from the future.
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return .justNow }
        if seconds < 3600 { return .minutes(seconds / 60) }
        if seconds < 86_400 { return .hours(seconds / 3600) }
        return .days(seconds / 86_400)
    }

    /// For the screen: "just now", "3m ago", "5h ago", "2d ago".
    public static func short(since date: Date, now: Date = Date()) -> String {
        switch unit(since: date, now: now) {
        case .justNow: "just now"
        case .minutes(let value): "\(value)m ago"
        case .hours(let value): "\(value)h ago"
        case .days(let value): "\(value)d ago"
        }
    }

    /// For VoiceOver, which reads "3m ago" as a letter rather than a duration.
    public static func spoken(since date: Date, now: Date = Date()) -> String {
        switch unit(since: date, now: now) {
        case .justNow: "just now"
        case .minutes(let value): "\(value) minute\(value == 1 ? "" : "s") ago"
        case .hours(let value): "\(value) hour\(value == 1 ? "" : "s") ago"
        case .days(let value): "\(value) day\(value == 1 ? "" : "s") ago"
        }
    }
}

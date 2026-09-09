import Foundation

/// Clock access as data, so anything time-dependent can be driven instantly in
/// tests rather than actually waiting. The viewer's countdown is the reason this
/// exists: asserting a 5-second expiry by sleeping five seconds would make the
/// suite slow and flaky in equal measure.
public struct TimeSource: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = TimeSource(
        now: { Date() },
        sleep: { try await Task.sleep(for: $0) }
    )
}

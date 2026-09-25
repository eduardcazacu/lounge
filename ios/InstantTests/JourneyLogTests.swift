import Foundation
import Testing
@testable import Instant

/// A clock the test moves by hand, so a journey's times are exact.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { current } }

    func advance(_ duration: Duration) {
        lock.withLock { current += duration }
    }
}

/// The timings are how a slow path gets found, and they are only worth that if
/// they are right: a journey ended by the wrong call, or a tap that goes
/// unrecorded, would point the search somewhere else.
@Suite("Journey timings")
struct JourneyLogTests {
    private let clock = ManualClock()
    private var log: JourneyLog { JourneyLog(now: { [clock] in clock.now }) }

    @Test("A journey records its total and each mark since its start")
    func recordsTotalsAndMarks() throws {
        let log = log
        log.begin(.openInstant, key: "a", attributes: ["source": "notification"])
        clock.advance(.milliseconds(120))
        log.mark(.openInstant, key: "a", "downloaded")
        clock.advance(.milliseconds(30))
        log.end(.openInstant, key: "a", outcome: "shown")

        let record = try #require(log.records().first)
        #expect(record.journey == .openInstant)
        #expect(record.totalMs == 150)
        #expect(record.outcome == "shown")
        #expect(record.attributes == ["source": "notification"])
        #expect(record.marks == [.init(name: "downloaded", ms: 120)])
    }

    /// The notification's journey begins at the tap; the inbox reaching the
    /// same instant must not restart the clock.
    @Test("A second begin under the same key keeps the first")
    func keepsRunningJourney() throws {
        let log = log
        log.begin(.openInstant, key: "a", attributes: ["source": "notification"])
        clock.advance(.milliseconds(500))
        log.begin(.openInstant, key: "a", attributes: ["source": "inbox"])
        log.end(.openInstant, key: "a", outcome: "shown")

        let record = try #require(log.records().first)
        #expect(record.totalMs == 500)
        #expect(record.attributes["source"] == "notification")
    }

    @Test("Restarting closes the old journey as abandoned")
    func restartAbandons() {
        let log = log
        log.begin(.capture)
        clock.advance(.milliseconds(40))
        log.begin(.capture, restart: true)
        log.end(.capture, outcome: "composing")

        #expect(log.records().map(\.outcome) == ["abandoned", "composing"])
    }

    @Test("Marking or ending a journey that is not running does nothing")
    func ignoresUnknownJourneys() {
        let log = log
        log.mark(.send, key: "x", "encoded")
        log.end(.send, key: "x")
        #expect(log.records().isEmpty)
    }

    /// A tapped notification whose instant never arrives must show up as a
    /// tap that went nowhere, not vanish.
    @Test("A journey left running past its limit is recorded as abandoned")
    func sweepsStaleJourneys() {
        let log = log
        log.begin(.openInstant, key: "lost")
        clock.advance(.seconds(121))
        log.begin(.capture)

        #expect(log.records().map(\.outcome) == ["abandoned"])
        #expect(!log.isRunning(.openInstant, key: "lost"))
    }

    @Test("Leaving the app closes what the person was watching, but not a send")
    func backgroundKeepsSends() {
        let log = log
        log.begin(.openInstant, key: "a")
        log.begin(.send, key: "s")
        log.didEnterBackground()

        #expect(log.records().map(\.outcome) == ["backgrounded"])
        #expect(log.isRunning(.send, key: "s"))
        #expect(log.hasEnteredBackground)
    }

    @Test("A send links to the capture before it, once")
    func linksCaptureToSend() {
        let log = log
        log.begin(.capture)
        clock.advance(.milliseconds(80))
        log.end(.capture, outcome: "composing", linkable: true)
        clock.advance(.seconds(4))

        #expect(log.takeLink(to: .capture) == ["captureMs": "80", "sinceMs": "4000"])
        #expect(log.takeLink(to: .capture).isEmpty)
    }

    @Test("A discarded capture is not linked to the next send")
    func forgetsDiscardedCapture() {
        let log = log
        log.begin(.capture)
        log.end(.capture, outcome: "composing", linkable: true)
        log.forgetLink(to: .capture)
        #expect(log.takeLink(to: .capture).isEmpty)
    }

    @Test("Marking every running journey reaches all of them")
    func marksEveryRunningJourney() {
        let log = log
        log.begin(.launch)
        log.begin(.openInstant, key: "a")
        clock.advance(.milliseconds(10))
        log.markRunning("tokenRefreshStarted")
        log.end(.launch)
        log.end(.openInstant, key: "a")

        #expect(log.records().allSatisfy { $0.marks == [.init(name: "tokenRefreshStarted", ms: 10)] })
    }

    @Test("Persisted journeys are read back from the file, one per line")
    func persistsToFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journeys-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = log
        log.persist(to: url)
        log.begin(.send, key: "s", attributes: ["media": "photo"])
        clock.advance(.milliseconds(900))
        log.end(.send, key: "s", outcome: "accepted")
        log.begin(.capture)
        log.end(.capture, outcome: "composing")

        let reread = log.records()
        #expect(reread.map(\.journey) == [.send, .capture])
        #expect(reread.first?.totalMs == 900)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)

        log.clear()
        #expect(log.records().isEmpty)
    }

    /// Console shows this line when nothing else can be got off the phone, so
    /// it has to carry the whole record.
    @Test("The log line carries the total, the outcome, the attributes and the marks")
    func summarisesForConsole() throws {
        let log = log
        log.begin(.openInstant, key: "a", attributes: ["media": "video", "launch": "cold"])
        clock.advance(.milliseconds(5))
        log.mark(.openInstant, key: "a", "downloaded")
        log.end(.openInstant, key: "a", outcome: "playing")

        let line = JourneyLog.summary(try #require(log.records().first))
        #expect(line == "journey=openInstant totalMs=5 outcome=playing launch=cold media=video downloaded@5")
    }

    @Test("A prewarmed launch is timed from now, not from the process start")
    func prewarmStartsNow() throws {
        let log = log
        log.beginLaunch(environment: ["ActivePrewarm": "1"])
        log.end(.launch)
        let record = try #require(log.records().first)
        #expect(record.attributes["prewarmed"] == "true")
        #expect(record.totalMs == 0)
    }

    @Test("A launch is timed from the process start")
    func launchStartsAtProcessStart() throws {
        #expect(JourneyLog.processStartDate().map { $0 <= Date() } == true)
    }
}

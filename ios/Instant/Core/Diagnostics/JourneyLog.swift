import Foundation
import os

/// The moments a person waits on, timed from the thing they did to the thing
/// they were waiting to see. See `wiki/ios-performance.md`.
public enum Journey: String, Codable, Sendable, CaseIterable {
    /// Process start to the first inbox fetch. Signed out, it ends at the first frame.
    case launch
    /// Back from the background to the inbox being refreshed.
    case resume
    /// A tap on a notification or an inbox row to the photo being on screen
    /// with its clock running, or the clip actually playing.
    case openInstant
    /// A shutter release, or a clip's end, to the compose screen.
    case capture
    /// A hold being recognised to the recorder actually running.
    case recordStart
    /// Send to the server accepting it. One per recipient.
    case send
}

/// One finished journey, as it is written to disk and exported.
public struct JourneyRecord: Codable, Equatable, Sendable {
    public struct Mark: Codable, Equatable, Sendable {
        public let name: String
        /// Since the journey started.
        public let ms: Int
    }

    public let journey: Journey
    public let startedAt: Date
    public let totalMs: Int
    public let outcome: String
    public let attributes: [String: String]
    public let marks: [Mark]
    public let build: String
    public let os: String
    public let device: String
}

/// Times the user journeys, and reports each one three ways: as a signpost
/// interval for Instruments, as one public line in the unified log, and as a
/// line of JSON in Application Support that Settings → Timings exports.
///
/// Three because a Release build on someone's phone is the only place the
/// numbers mean anything (a Debug build compiles libwebp at `-O0`, and the
/// Simulator has neither a Secure Enclave nor a camera), and each way reaches
/// that phone differently: Instruments needs it on a cable, `log collect` needs
/// a Mac, and the file only needs a share sheet. Nothing leaves the device on
/// its own — see `wiki/decisions.md`.
///
/// A journey is named by its kind and a key, so the places that mark it do not
/// have to hand anything to one another: the notification tap starts the one
/// the viewer finishes, keyed by the instant's id. Marks and ends on a journey
/// that is not running do nothing, which is what lets every call site stay one
/// unconditional line.
public final class JourneyLog: @unchecked Sendable {
    public static let shared = JourneyLog()

    static let subsystem = "com.eduardcazacu.instant"

    private struct Running {
        let started: ContinuousClock.Instant
        let startedAt: Date
        var attributes: [String: String]
        var marks: [JourneyRecord.Mark]
        let signpost: OSSignpostIntervalState
    }

    private struct RunningKey: Hashable {
        let journey: Journey
        let key: String
    }

    private let lock = NSLock()
    private var running: [RunningKey: Running] = [:]
    /// Finished journeys from this run, newest last, for when nothing is persisted.
    private var recent: [JourneyRecord] = []
    /// When a linkable journey last finished, for the one that follows it to refer to.
    private var lastEnded: [Journey: (at: ContinuousClock.Instant, totalMs: Int)] = [:]
    private var fileURL: URL?
    private var enteredBackground = false

    private let queue = DispatchQueue(label: "com.eduardcazacu.instant.journeys")
    private let now: @Sendable () -> ContinuousClock.Instant
    private let wallNow: @Sendable () -> Date
    private let signposter = OSSignposter(subsystem: JourneyLog.subsystem, category: .pointsOfInterest)
    private let logger = Logger(subsystem: JourneyLog.subsystem, category: "journeys")

    /// The outcomes that mean the person got what they were waiting for. The
    /// rest say how long it took to fail, which is a different question.
    public static let successes: Set<String> = ["ok", "shown", "playing", "composing", "recording", "accepted"]

    static let recentLimit = 500
    /// The file is cut back to `keptLines` whenever it is found holding more
    /// than `lineLimit`, at launch, so it never grows without bound.
    static let lineLimit = 2000
    static let keptLines = 1500

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.wallNow = wallNow
    }

    // MARK: - Persistence

    public static var defaultFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("journeys.jsonl")
    }

    /// Only the app's own environment calls this. Tests and the stubbed UI-test
    /// launches keep their journeys in memory, so no run inherits another's.
    public func persist(to url: URL) {
        lock.withLock { fileURL = url }
        queue.async { Self.trim(url) }
    }

    public var exportURL: URL? { lock.withLock { fileURL } }

    /// Every finished journey on record, oldest first.
    public func records() -> [JourneyRecord] {
        guard let url = lock.withLock({ fileURL }) else {
            return lock.withLock { recent }
        }
        return queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                try? Self.decoder.decode(JourneyRecord.self, from: Data(line.utf8))
            }
        }
    }

    public func clear() {
        let url = lock.withLock {
            recent = []
            return fileURL
        }
        guard let url else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Journeys

    /// Starts a journey. One already running under the same key is left alone,
    /// so a notification's journey survives the inbox reaching the same
    /// instant — unless `restart`, which closes the old one as abandoned.
    public func begin(
        _ journey: Journey,
        key: String = "",
        attributes: [String: String] = [:],
        startedAt: ContinuousClock.Instant? = nil,
        restart: Bool = false
    ) {
        let instant = now()
        var abandoned: [(RunningKey, Running)] = []
        lock.withLock {
            abandoned = sweep(at: instant)
            let id = RunningKey(journey: journey, key: key)
            if let existing = running[id] {
                guard restart else { return }
                abandoned.append((id, existing))
            }
            let started = startedAt ?? instant
            running[id] = Running(
                started: started,
                startedAt: wallNow().addingTimeInterval(-Self.seconds(instant - started)),
                attributes: attributes,
                marks: [],
                signpost: beginSignpost(journey)
            )
        }
        for (id, run) in abandoned { finish(id, run, outcome: "abandoned", at: instant) }
    }

    public func isRunning(_ journey: Journey, key: String = "") -> Bool {
        lock.withLock { running[RunningKey(journey: journey, key: key)] != nil }
    }

    public func mark(_ journey: Journey, key: String = "", _ name: String) {
        let instant = now()
        let id = RunningKey(journey: journey, key: key)
        let state: OSSignpostIntervalState? = lock.withLock {
            guard var run = running[id] else { return nil }
            run.marks.append(.init(name: name, ms: Self.milliseconds(instant - run.started)))
            running[id] = run
            return run.signpost
        }
        guard state != nil else { return }
        signposter.emitEvent("mark", "\(journey.rawValue, privacy: .public) \(name, privacy: .public)")
    }

    /// Marks every running journey — for things that hold them all up at once,
    /// such as the access token being refreshed.
    public func markRunning(_ name: String) {
        let instant = now()
        lock.withLock {
            for (id, var run) in running {
                run.marks.append(.init(name: name, ms: Self.milliseconds(instant - run.started)))
                running[id] = run
            }
        }
    }

    public func annotate(_ journey: Journey, key: String = "", _ attributes: [String: String]) {
        lock.withLock {
            let id = RunningKey(journey: journey, key: key)
            guard var run = running[id] else { return }
            run.attributes.merge(attributes) { _, new in new }
            running[id] = run
        }
    }

    /// `linkable` keeps the journey for `takeLink`, for the one that follows
    /// it to say how it began.
    public func end(_ journey: Journey, key: String = "", outcome: String = "ok", linkable: Bool = false) {
        let instant = now()
        let id = RunningKey(journey: journey, key: key)
        guard let run = lock.withLock({ running.removeValue(forKey: id) }) else { return }
        let total = finish(id, run, outcome: outcome, at: instant)
        if linkable { lock.withLock { lastEnded[journey] = (instant, total) } }
    }

    /// How long ago a linkable `journey` finished and how long it took, spent
    /// on reading: a send asks once how its photo was taken, and the next send
    /// must not claim the same capture.
    public func takeLink(to journey: Journey) -> [String: String] {
        let instant = now()
        guard let last = lock.withLock({ lastEnded.removeValue(forKey: journey) }) else { return [:] }
        return [
            "\(journey.rawValue)Ms": String(last.totalMs),
            "sinceMs": String(Self.milliseconds(instant - last.at)),
        ]
    }

    public func forgetLink(to journey: Journey) {
        _ = lock.withLock { lastEnded.removeValue(forKey: journey) }
    }

    // MARK: - App lifecycle

    /// Whether this process has been in the background yet: a notification
    /// tapped before it has is a cold start.
    public var hasEnteredBackground: Bool { lock.withLock { enteredBackground } }

    /// Closes everything the person was watching. A send keeps going in the
    /// background, and so does its journey.
    public func didEnterBackground() {
        let instant = now()
        let closed: [(RunningKey, Running)] = lock.withLock {
            enteredBackground = true
            let closed = running.filter { $0.key.journey != .send }
            for id in closed.keys { running[id] = nil }
            return Array(closed)
        }
        for (id, run) in closed { finish(id, run, outcome: "backgrounded", at: instant) }
    }

    /// Starts `.launch` at the moment the process did, which is before any of
    /// this app's code ran. A prewarmed launch was started by iOS ahead of the
    /// tap, so its process start says nothing about the wait; it starts here.
    public func beginLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let prewarmed = environment["ActivePrewarm"] == "1"
        var startedAt: ContinuousClock.Instant?
        if !prewarmed, let processStart = Self.processStartDate() {
            let age = wallNow().timeIntervalSince(processStart)
            // A clock that moved under the process gives a nonsense age.
            if age >= 0, age < 60 { startedAt = now() - .seconds(age) }
        }
        begin(.launch, attributes: ["prewarmed": String(prewarmed)], startedAt: startedAt)
        mark(.launch, "appInit")
    }

    static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    // MARK: - Internals

    /// How long each kind may run before it is assumed nobody is waiting any
    /// more. A tapped notification whose instant never arrives is exactly what
    /// this is for: it is recorded as abandoned rather than never recorded.
    static func limit(for journey: Journey) -> Duration {
        journey == .send ? .seconds(600) : .seconds(120)
    }

    /// Called with the lock held.
    private func sweep(at instant: ContinuousClock.Instant) -> [(RunningKey, Running)] {
        let stale = running.filter { instant - $0.value.started > Self.limit(for: $0.key.journey) }
        for id in stale.keys { running[id] = nil }
        return Array(stale)
    }

    @discardableResult
    private func finish(
        _ id: RunningKey, _ run: Running, outcome: String, at instant: ContinuousClock.Instant
    ) -> Int {
        let total = Self.milliseconds(instant - run.started)
        endSignpost(id.journey, run.signpost, outcome: outcome)
        let record = JourneyRecord(
            journey: id.journey,
            startedAt: run.startedAt,
            totalMs: total,
            outcome: outcome,
            attributes: run.attributes,
            marks: run.marks,
            build: Self.build,
            os: Self.osVersion,
            device: Self.deviceModel
        )
        let url: URL? = lock.withLock {
            recent.append(record)
            if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
            return fileURL
        }
        logger.notice("\(Self.summary(record), privacy: .public)")
        if let url, let line = try? Self.encoder.encode(record) {
            queue.async { Self.append(line, to: url) }
        }
        return total
    }

    /// One line, readable in Console without the file: the total, then each
    /// mark's time since the start.
    static func summary(_ record: JourneyRecord) -> String {
        let attributes = record.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let marks = record.marks.map { "\($0.name)@\($0.ms)" }
        return (["journey=\(record.journey.rawValue)", "totalMs=\(record.totalMs)", "outcome=\(record.outcome)"]
            + attributes + marks).joined(separator: " ")
    }

    // `beginInterval` and `endInterval` take a `StaticString`, so the name
    // cannot come from the enum's raw value.
    private func beginSignpost(_ journey: Journey) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        switch journey {
        case .launch: return signposter.beginInterval("launch", id: id)
        case .resume: return signposter.beginInterval("resume", id: id)
        case .openInstant: return signposter.beginInterval("openInstant", id: id)
        case .capture: return signposter.beginInterval("capture", id: id)
        case .recordStart: return signposter.beginInterval("recordStart", id: id)
        case .send: return signposter.beginInterval("send", id: id)
        }
    }

    private func endSignpost(_ journey: Journey, _ state: OSSignpostIntervalState, outcome: String) {
        switch journey {
        case .launch: signposter.endInterval("launch", state, "\(outcome, privacy: .public)")
        case .resume: signposter.endInterval("resume", state, "\(outcome, privacy: .public)")
        case .openInstant: signposter.endInterval("openInstant", state, "\(outcome, privacy: .public)")
        case .capture: signposter.endInterval("capture", state, "\(outcome, privacy: .public)")
        case .recordStart: signposter.endInterval("recordStart", state, "\(outcome, privacy: .public)")
        case .send: signposter.endInterval("send", state, "\(outcome, privacy: .public)")
        }
    }

    private static func append(_ line: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }

    private static func trim(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > lineLimit else { return }
        let kept = lines.suffix(keptLines).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: url, options: .atomic)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let build: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }()

    static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    /// `iPhone17,1` rather than a marketing name: the mapping changes every
    /// year, and the identifier is what a crash log uses too.
    static let deviceModel: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}

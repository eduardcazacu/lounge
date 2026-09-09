import Foundation
import os

public enum InstantConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case open
    case offline
    /// The backend has no Durable Object binding (`/ws` answered 501). Retrying
    /// cannot fix that, so the app polls the inbox instead of reconnecting.
    case unsupported
}

public extension InstantConnectionState {
    /// A short message when live delivery is genuinely broken, or `nil` when
    /// there is nothing worth saying.
    ///
    /// `.connecting` and `.idle` are momentary and normal at launch, and
    /// `.open` is simply the happy path. An indicator that is always on screen
    /// is ambient noise nobody reads — and, worse, it reads as a warning.
    var warningText: String? {
        switch self {
        case .open, .connecting, .idle:
            return nil
        case .offline:
            return "Reconnecting"
        case .unsupported:
            return "Live updates off"
        }
    }

    /// Reconnecting fixes itself; no Durable Object does not.
    var isRecoverable: Bool { self != .unsupported }
}

public enum InboxSocketEvent: Equatable, Sendable {
    case state(InstantConnectionState)
    case wire(InstantWireEvent)
    /// Emitted before each connection attempt; the owner drains `GET /inbox`.
    /// The socket alone is not a delivery guarantee — anything queued while
    /// disconnected only arrives this way.
    case shouldDrainInbox
}

/// Exponential backoff, 1s doubling to a 30s ceiling, reset on a successful
/// open. Pulled out of the socket so the schedule can be asserted directly
/// instead of inferred from timing.
public struct ReconnectBackoff: Equatable, Sendable {
    public static let minimum: Duration = .seconds(1)
    public static let maximum: Duration = .seconds(30)

    private(set) var current: Duration = ReconnectBackoff.minimum

    public init() {}

    public mutating func next() -> Duration {
        let delay = current
        current = min(current * 2, Self.maximum)
        return delay
    }

    public mutating func reset() {
        current = Self.minimum
    }
}

public protocol InboxSocketProtocol: Sendable {
    var events: AsyncStream<InboxSocketEvent> { get }
    func start(deviceId: String)
    func stop()
}

/// Instant's realtime inbox connection.
///
/// Mirrors `frontend/src/hooks/useInstant.ts`: drain the inbox first, then mint
/// a fresh 60-second ticket, then connect. The ticket is the only query
/// parameter — the access token never goes in a URL.
public final class InboxSocket: InboxSocketProtocol, @unchecked Sendable {
    /// A literal text frame, answered by the Durable Object's
    /// `setWebSocketAutoResponse` pair without waking it from hibernation.
    /// Deliberately not `URLSessionWebSocketTask.sendPing`, which sends a
    /// protocol-level ping the auto-response never sees.
    static let pingFrame = "ping"
    static let pingInterval: Duration = .seconds(25)

    private let api: InstantAPIProtocol
    private let config: AppConfig
    private let session: URLSession
    private let clock: any Clock<Duration>

    public let events: AsyncStream<InboxSocketEvent>
    private let continuation: AsyncStream<InboxSocketEvent>.Continuation

    /// `NSLock` is unavailable from async contexts; this one is held only
    /// around a couple of pointer swaps and never across a suspension.
    private struct State {
        var runLoop: Task<Void, Never>?
        var task: URLSessionWebSocketTask?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        api: InstantAPIProtocol,
        config: AppConfig = .production,
        session: URLSession? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.api = api
        self.config = config
        self.session = session ?? URLSession(configuration: .default)
        self.clock = clock
        (events, continuation) = AsyncStream<InboxSocketEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
    }

    public func start(deviceId: String) {
        state.withLock { state in
            guard state.runLoop == nil else { return }
            state.runLoop = Task { [weak self] in await self?.run(deviceId: deviceId) }
        }
    }

    public func stop() {
        state.withLock { state in
            state.runLoop?.cancel()
            state.runLoop = nil
            state.task?.cancel(with: .goingAway, reason: nil)
            state.task = nil
        }
        continuation.yield(.state(.idle))
    }

    // MARK: - Connection loop

    private func run(deviceId: String) async {
        var backoff = ReconnectBackoff()

        while !Task.isCancelled {
            continuation.yield(.state(.connecting))
            continuation.yield(.shouldDrainInbox)

            let ticket: String
            do {
                ticket = try await api.socketTicket(deviceId: deviceId)
            } catch let error as APIError where error.isRealtimeUnsupported {
                continuation.yield(.state(.unsupported))
                return
            } catch {
                continuation.yield(.state(.offline))
                guard await sleep(backoff.next()) else { return }
                continue
            }

            let connected = await connect(ticket: ticket)
            if connected {
                backoff.reset()
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.state(.offline))
            guard await sleep(backoff.next()) else { return }
        }
    }

    /// Runs one connection to completion. Returns whether it ever opened, which
    /// is what decides if the backoff resets.
    private func connect(ticket: String) async -> Bool {
        var components = URLComponents(
            url: config.webSocketBaseURL.appendingPathComponent("api/v1/instant/ws"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = components.url else { return false }

        let socket = session.webSocketTask(with: url)
        state.withLock { $0.task = socket }
        socket.resume()

        continuation.yield(.state(.open))

        let pinger = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await sleep(Self.pingInterval) else { return }
                do {
                    try await socket.send(.string(Self.pingFrame))
                } catch {
                    return
                }
            }
        }
        defer {
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            state.withLock { if $0.task === socket { $0.task = nil } }
        }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if let event = Self.event(from: message) {
                    continuation.yield(.wire(event))
                }
            } catch {
                return true
            }
        }
        return true
    }

    /// The auto-response replies with the bare string `pong`, which is not JSON.
    /// Anything undecodable is ignored rather than treated as an error.
    static func event(from message: URLSessionWebSocketTask.Message) -> InstantWireEvent? {
        switch message {
        case .string(let text):
            guard text != "pong" else { return nil }
            return InstantWireEvent.decode(from: Data(text.utf8))
        case .data(let data):
            return InstantWireEvent.decode(from: data)
        @unknown default:
            return nil
        }
    }

    private func sleep(_ duration: Duration) async -> Bool {
        do {
            try await clock.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

import Foundation

/// One HTTP request, described declaratively so tests can assert on the URL,
/// method and body a call produces rather than on network behaviour.
public struct APIRequest: Sendable {
    public enum Body: Sendable {
        case empty
        case json(Data)
        case multipart([MultipartPart])
    }

    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var body: Body
    /// Whether to attach the bearer token, and therefore whether a 403 is worth
    /// a refresh-and-retry. Sign-in must be false: its 403s are real answers
    /// ("wrong password", "pending approval"), not expiry.
    public var authenticated: Bool

    public init(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Body = .empty,
        authenticated: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.authenticated = authenticated
    }

    public static func get(_ path: String, query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: "GET", path: path, query: query)
    }

    public static func post(_ path: String, json: (some Encodable)? = Optional<Never>.none) -> APIRequest {
        let body: Body = json.flatMap { try? JSONEncoder().encode($0) }.map(Body.json) ?? .json(Data("{}".utf8))
        return APIRequest(method: "POST", path: path, body: body)
    }

    public static func put(_ path: String, json: some Encodable) -> APIRequest {
        APIRequest(
            method: "PUT",
            path: path,
            body: (try? JSONEncoder().encode(json)).map(Body.json) ?? .json(Data("{}".utf8))
        )
    }
}

public struct MultipartPart: Sendable {
    public let name: String
    public let filename: String?
    public let contentType: String?
    public let data: Data

    public init(name: String, filename: String? = nil, contentType: String? = nil, data: Data) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    public static func text(_ name: String, _ value: String) -> MultipartPart {
        MultipartPart(name: name, data: Data(value.utf8))
    }
}

/// Serialises refresh attempts so a burst of 403s triggers exactly one.
actor RefreshCoordinator {
    private var inFlight: Task<Bool, Never>?

    func refresh(using work: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task<Bool, Never> { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

public protocol APIClientProtocol: Sendable {
    func data(for request: APIRequest) async throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from request: APIRequest) async throws -> T
    func send(_ request: APIRequest) async throws
}

public extension APIClientProtocol {
    func decode<T: Decodable>(_ type: T.Type, from request: APIRequest) async throws -> T {
        try JSONDecoder().decode(type, from: try await data(for: request))
    }

    func send(_ request: APIRequest) async throws {
        _ = try await data(for: request)
    }
}

public final class APIClient: APIClientProtocol, @unchecked Sendable {
    let config: AppConfig
    let session: URLSession
    let tokens: TokenStoring
    private let refresher = RefreshCoordinator()
    /// Called when refresh fails and the session is genuinely over.
    private let onSessionExpired: @Sendable () -> Void
    private let now: @Sendable () -> Date

    /// How close to its expiry a token is refreshed before use rather than
    /// sent. Wide enough to cover the request's own flight and a phone clock
    /// that runs a little behind the server's.
    static let expiryMargin: TimeInterval = 30

    public init(
        config: AppConfig = .production,
        tokens: TokenStoring,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        onSessionExpired: @escaping @Sendable () -> Void = {}
    ) {
        self.config = config
        self.tokens = tokens
        self.onSessionExpired = onSessionExpired
        self.now = now
        self.session = session ?? Self.makeSession()
    }

    /// The refresh token arrives as an HttpOnly cookie on `POST /user/signin`
    /// and is replayed by `POST /user/refresh`, so the session needs a cookie
    /// jar. Without this the app would silently log itself out every 15 minutes.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    // MARK: - Request building

    func urlRequest(for request: APIRequest) -> URLRequest {
        var components = URLComponents(
            url: config.apiBaseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        )!
        if !request.query.isEmpty { components.queryItems = request.query }

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("Instant-iOS", forHTTPHeaderField: "User-Agent")

        switch request.body {
        case .empty:
            if request.method != "GET" {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.httpBody = Data("{}".utf8)
            }
        case .json(let data):
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        case .multipart(let parts):
            let boundary = "instant.\(UUID().uuidString)"
            urlRequest.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            urlRequest.httpBody = Self.multipartBody(parts: parts, boundary: boundary)
        }

        if request.authenticated, let token = tokens.token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    static func multipartBody(parts: [MultipartPart], boundary: String) -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("\(disposition)\r\n".utf8))
            if let contentType = part.contentType {
                body.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: - Sending

    public func data(for request: APIRequest) async throws -> Data {
        // A token read off the Keychain on a cold start has usually aged out:
        // it lives fifteen minutes, and a notification is rarely tapped that
        // soon after the last launch. Sending it anyway costs a 403 round trip
        // before the refresh that was always going to happen — measured at
        // 0.6–1.3 s on the path to a photo (wiki/ios-performance.md). A failed
        // refresh here is not the end of the session: the request goes out as
        // it would have, and the 403 path below decides.
        if shouldRefreshFirst(request) {
            _ = await refreshAccessToken()
        }
        do {
            return try await perform(request)
        } catch let error as APIError where shouldRetryAfterRefresh(error, for: request) {
            // 403 on an authenticated call means the 15-minute access token
            // aged out. One refresh, one retry — matching the web client's
            // `__authRetried` guard, so a genuinely revoked session surfaces
            // instead of looping.
            guard await refreshAccessToken() else {
                onSessionExpired()
                throw error
            }
            return try await perform(request)
        }
    }

    /// Refresh is only ever a way to *renew* a session, never to acquire one.
    ///
    /// Without the `tokens.token != nil` condition, a signed-out app answers its
    /// first 403 by refreshing, and `POST /user/refresh` authenticates purely
    /// from the `refresh_token` cookie — so the app would silently adopt
    /// whichever account that ambient cookie belongs to and come up signed in as
    /// them. Observed on a Simulator, where cookie and keychain storage are not
    /// sandboxed per app the way they are on a device. Signing in has to be
    /// something a person does.
    func shouldRetryAfterRefresh(_ error: APIError, for request: APIRequest) -> Bool {
        error.isAuthFailure && request.authenticated && tokens.token != nil
    }

    /// Only a token this client holds and can read an expiry from. The rule in
    /// `shouldRetryAfterRefresh` applies here too: no token, no refresh.
    func shouldRefreshFirst(_ request: APIRequest) -> Bool {
        guard request.authenticated,
              let token = tokens.token,
              let expiry = SessionStore.expiry(ofJWT: token)
        else { return false }
        return expiry.timeIntervalSince(now()) < Self.expiryMargin
    }

    private func perform(_ request: APIRequest) async throws -> Data {
        let (data, response) = try await session.data(for: urlRequest(for: request))
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.decode(status: http.statusCode, data: data)
        }
        return data
    }

    func refreshAccessToken() async -> Bool {
        await refresher.refresh { [weak self] in
            guard let self else { return false }
            // Everything running is held up by this, which is what makes an
            // expired token visible in the timings.
            JourneyLog.shared.markRunning("tokenRefreshStarted")
            defer { JourneyLog.shared.markRunning("tokenRefreshed") }
            var request = URLRequest(
                url: config.apiBaseURL.appendingPathComponent("api/v1/user/refresh")
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(SignInResponse.self, from: data)
            else { return false }

            tokens.setToken(decoded.token)
            return true
        }
    }
}

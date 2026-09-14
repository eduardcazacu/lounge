import Foundation

/// Where the app points. Mirrors `frontend/src/config.ts`, including deriving
/// the socket origin from the API origin rather than configuring it separately —
/// there is only ever one backend URL to get wrong.
public struct AppConfig: Sendable {
    public let apiBaseURL: URL
    public let webAppURL: URL

    public var webSocketBaseURL: URL {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = apiBaseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    public init(apiBaseURL: URL, webAppURL: URL) {
        self.apiBaseURL = apiBaseURL
        self.webAppURL = webAppURL
    }

    /// Published in the app and on /support, as Guideline 1.2 asks.
    public static let supportEmail = "hello@eduardcazacu.com"

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://api.lounge.eduardcazacu.com")!,
        webAppURL: URL(string: "https://lounge.eduardcazacu.com")!
    )

    /// `npm run dev:worker` in backend/. Plain `npm run dev` has no Durable
    /// Object, so `/ws` answers 501 and the app falls back to polling the inbox.
    public static let localWorker = AppConfig(
        apiBaseURL: URL(string: "http://localhost:8787")!,
        webAppURL: URL(string: "http://localhost:5173")!
    )
}

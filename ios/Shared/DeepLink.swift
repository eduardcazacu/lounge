import Foundation

/// The one URL the app answers to, and the only thing the widget can say when
/// someone taps it.
///
/// Both ways in from outside the app — a tapped notification, a tapped widget —
/// mean the same thing: someone has something waiting. That is the inbox. The
/// app otherwise opens on the camera, which is right for a cold launch and
/// wrong for a tap that was about an instant someone sent you.
///
/// It lives in `Shared` because the widget builds the URL and the app reads it;
/// a scheme agreed on in two places is a scheme that eventually disagrees.
public enum DeepLink: Equatable, Sendable {
    /// Open the inbox, and the named instant with it if it is still there.
    case inbox(instantId: String?)

    public static let scheme = "instant"
    private static let inboxHost = "inbox"
    private static let instantQuery = "instant"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.inboxHost
        if case let .inbox(instantId) = self, let instantId, !instantId.isEmpty {
            components.queryItems = [URLQueryItem(name: Self.instantQuery, value: instantId)]
        }
        // Every part of this is fixed or percent-encoded by URLComponents, so
        // there is no id that can fail to produce a URL.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Nil for anything that is not ours — the app should ignore a URL it does
    /// not recognise rather than guess that it meant the inbox.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.inboxHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let id = items?.first { $0.name == Self.instantQuery }?.value
        self = .inbox(instantId: (id?.isEmpty == false) ? id : nil)
    }
}

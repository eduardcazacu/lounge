import Foundation

/// Every error body in this API uses the key `msg`; zod failures add `errors`
/// with `formErrors` and `fieldErrors`.
public struct APIError: Error, Equatable {
    public let status: Int
    public let message: String
    public let fieldErrors: [String: [String]]

    public init(status: Int, message: String, fieldErrors: [String: [String]] = [:]) {
        self.status = status
        self.message = message
        self.fieldErrors = fieldErrors
    }

    /// The backend answers auth failures with 403, never 401 — worth stating
    /// plainly, because the usual instinct is to key refresh logic off 401 and
    /// then wonder why the session never recovers.
    public var isAuthFailure: Bool { status == 403 }

    /// The instant is gone: opened already (possibly on another of this user's
    /// devices), or expired.
    public var isGone: Bool { status == 410 }

    /// No Durable Object binding — the backend is running under `tsx`, not
    /// Wrangler. Retrying will not help.
    public var isRealtimeUnsupported: Bool { status == 501 }

    private struct Body: Decodable {
        struct Errors: Decodable { let fieldErrors: [String: [String]]? }
        let msg: String?
        let errors: Errors?
    }

    static func decode(status: Int, data: Data) -> APIError {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return APIError(
                status: status,
                message: text.isEmpty ? "Request failed (\(status))" : text
            )
        }
        return APIError(
            status: status,
            message: body.msg ?? "Request failed (\(status))",
            fieldErrors: body.errors?.fieldErrors ?? [:]
        )
    }
}

public enum TransportError: Error, Equatable {
    case notHTTP
    case sessionExpired
}

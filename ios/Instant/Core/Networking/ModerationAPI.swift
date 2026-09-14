import Foundation

/// Why something is being reported. Mirrors `reportReasons` in
/// `common/src/index.ts`; the raw values are the wire format.
public enum ReportReason: String, CaseIterable, Codable, Sendable, Identifiable {
    case nudity
    case harassment
    case violence
    case spam
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nudity: "Nudity or sexual content"
        case .harassment: "Harassment or bullying"
        case .violence: "Violence or threats"
        case .spam: "Spam or scam"
        case .other: "Something else"
        }
    }
}

public struct ReportDraft: Equatable, Sendable {
    public var reportedUserId: Int
    public var instantId: String?
    public var reason: ReportReason
    public var details: String?
    public var alsoBlock: Bool
    /// The reporter's own copy of the photo, re-encoded. Only present when they
    /// chose to attach it — the one way an instant's plaintext reaches the server.
    public var evidence: Data?

    public init(
        reportedUserId: Int,
        instantId: String? = nil,
        reason: ReportReason,
        details: String? = nil,
        alsoBlock: Bool = true,
        evidence: Data? = nil
    ) {
        self.reportedUserId = reportedUserId
        self.instantId = instantId
        self.reason = reason
        self.details = details
        self.alsoBlock = alsoBlock
        self.evidence = evidence
    }
}

public struct BlockedUser: Codable, Equatable, Identifiable, Sendable {
    public let userId: Int
    public let name: String?
    public let themeKey: String
    public let profilePictureUrl: String?
    public let blockedAt: String

    public var id: Int { userId }
    public var displayName: String { name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Someone" }
}

/// Reporting and blocking — App Store Guideline 1.2. See `backend/README.md`.
public protocol ModerationAPIProtocol: Sendable {
    func blockedUsers() async throws -> [BlockedUser]
    func block(userId: Int) async throws
    func unblock(userId: Int) async throws
    func report(_ draft: ReportDraft) async throws
}

public struct ModerationAPI: ModerationAPIProtocol {
    let client: APIClientProtocol
    static let base = "api/v1/moderation"

    public init(client: APIClientProtocol) {
        self.client = client
    }

    private struct BlocksResponse: Decodable { let blocks: [BlockedUser] }
    private struct BlockBody: Encodable { let userId: Int }

    public func blockedUsers() async throws -> [BlockedUser] {
        try await client.decode(BlocksResponse.self, from: .get("\(Self.base)/blocks")).blocks
    }

    public func block(userId: Int) async throws {
        try await client.send(.post("\(Self.base)/blocks", json: BlockBody(userId: userId)))
    }

    public func unblock(userId: Int) async throws {
        try await client.send(APIRequest(method: "DELETE", path: "\(Self.base)/blocks/\(userId)"))
    }

    private struct ReportPayload: Encodable {
        let reportedUserId: Int
        let instantId: String?
        let reason: ReportReason
        let details: String?
        let alsoBlock: Bool
    }

    public func report(_ draft: ReportDraft) async throws {
        let payload = ReportPayload(
            reportedUserId: draft.reportedUserId,
            instantId: draft.instantId,
            reason: draft.reason,
            details: draft.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            alsoBlock: draft.alsoBlock
        )
        var parts = [MultipartPart(name: "payload", data: try JSONEncoder().encode(payload))]
        if let evidence = draft.evidence {
            parts.append(MultipartPart(
                name: "evidence", filename: "evidence.webp", contentType: "image/webp", data: evidence
            ))
        }
        try await client.send(APIRequest(
            method: "POST", path: "\(Self.base)/reports", body: .multipart(parts)
        ))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

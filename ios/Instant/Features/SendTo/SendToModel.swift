#if canImport(UIKit)
import Foundation
import Observation

@MainActor
@Observable
public final class SendToModel {
    public struct Candidate: Identifiable, Equatable, Sendable {
        public let user: UserSummary
        /// Nobody can be sent to before they have enrolled a device — there
        /// would be no public key to wrap the content key for.
        public var isEnrolled: Bool?
        /// When you last sent to or heard from them, if ever.
        public var lastInteraction: Date?

        public var id: Int { user.id }
    }

    public private(set) var candidates: [Candidate] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var selectedId: Int?

    /// People you have exchanged an instant with, most recent first.
    public var recent: [Candidate] {
        candidates.filter { $0.lastInteraction != nil }
    }

    /// Everyone else, in the order the server sent them.
    public var everyoneElse: [Candidate] {
        candidates.filter { $0.lastInteraction == nil }
    }

    /// With nothing recent there is only one group, and a lone header over the
    /// whole list labels nothing.
    public var showsSections: Bool { !recent.isEmpty }

    private let userAPI: UserAPIProtocol
    private let instantAPI: InstantAPIProtocol
    private let recentContacts: RecentContactsStoring
    private let currentUserId: Int?

    public init(
        userAPI: UserAPIProtocol,
        instantAPI: InstantAPIProtocol,
        recentContacts: RecentContactsStoring,
        currentUserId: Int?
    ) {
        self.userAPI = userAPI
        self.instantAPI = instantAPI
        self.recentContacts = recentContacts
        self.currentUserId = currentUserId
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // The list includes the caller; the send endpoint 400s on a
            // self-send, so filter rather than let someone tap into an error.
            let users = try await userAPI.users().filter { $0.id != currentUserId }
            candidates = Self.ordered(users, recentContacts: recentContacts, currentUserId: currentUserId)
            await loadEnrollment(for: users)
        } catch {
            errorMessage = "Could not load your Lounge."
        }
    }

    /// People you have talked to, most recent first, then everyone else in the
    /// order the server sent them.
    ///
    /// The server's order is by most recent *Lounge post*, which is a fine
    /// default for someone you have never messaged and says nothing at all
    /// about who you send photos to.
    static func ordered(
        _ users: [UserSummary],
        recentContacts: RecentContactsStoring,
        currentUserId: Int?
    ) -> [Candidate] {
        let candidates = users.enumerated().map { position, user in
            (
                position: position,
                candidate: Candidate(
                    user: user,
                    isEnrolled: nil,
                    lastInteraction: currentUserId.flatMap {
                        recentContacts.lastInteraction(with: user.id, for: $0)
                    }
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            switch (lhs.candidate.lastInteraction, rhs.candidate.lastInteraction) {
            case let (left?, right?):
                // Same instant for both is possible in tests and on a fast
                // exchange; fall back to the server order so it stays stable.
                return left == right ? lhs.position < rhs.position : left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.position < rhs.position
            }
        }
        .map(\.candidate)
    }

    /// Enrollment is per-user and the key directory is a separate call, so this
    /// resolves in the background and rows settle from "checking" to enabled or
    /// disabled.
    private func loadEnrollment(for users: [UserSummary]) async {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for user in users {
                group.addTask { [instantAPI] in
                    let devices = try? await instantAPI.keys(forUserId: user.id).theirs
                    return (user.id, !(devices ?? []).isEmpty)
                }
            }
            for await (id, enrolled) in group {
                guard let index = candidates.firstIndex(where: { $0.id == id }) else { continue }
                candidates[index].isEnrolled = enrolled
            }
        }
    }
}
#endif

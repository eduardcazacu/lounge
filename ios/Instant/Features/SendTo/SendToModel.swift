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
        /// When you last exchanged an instant with them, if ever. ISO 8601, so
        /// it sorts chronologically as a plain string.
        public var lastInteractionAt: String?

        public var id: Int { user.id }
    }

    public private(set) var candidates: [Candidate] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Everyone ticked. A photo can go to several people at once, and each of
    /// them gets an instant of their own.
    public var selectedIds: Set<Int> = []

    /// Who is ticked, in the order the list shows them.
    public var selected: [Candidate] {
        candidates.filter { selectedIds.contains($0.id) }
    }

    /// Everyone a photo can actually reach: the people with a device enrolled.
    public var everyoneReachable: [Candidate] {
        candidates.filter { $0.isEnrolled == true }
    }

    /// "All" waits until every row has settled. Offered earlier, it would mean
    /// "everyone whose check happened to come back first", and the count in
    /// its confirmation would be a guess.
    public var canSendToEveryone: Bool {
        !everyoneReachable.isEmpty && !candidates.contains { $0.isEnrolled == nil }
    }

    /// Names one or two people and counts past that; a send button is not the
    /// place for a list.
    public var sendTitle: String {
        let names = selected.map(\.user.displayName)
        switch names.count {
        case 0: return "Send"
        case 1: return "Send to \(names[0])"
        case 2: return "Send to \(names[0]) and \(names[1])"
        default: return "Send to \(names.count) people"
        }
    }

    /// What the "All" confirmation says. The count is what makes it a
    /// confirmation rather than a speed bump: it is the number of people about
    /// to get the photo.
    public var everyoneMessage: String {
        let count = everyoneReachable.count
        return count == 1
            ? "This photo will go to the one person who has Instant set up."
            : "This photo will go to all \(count) people who have Instant set up."
    }

    public func toggle(_ id: Int) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// People you have exchanged an instant with, most recent first.
    public var recent: [Candidate] {
        candidates.filter { $0.lastInteractionAt != nil }
    }

    /// Everyone else, in the order the server sent them.
    public var everyoneElse: [Candidate] {
        candidates.filter { $0.lastInteractionAt == nil }
    }

    /// With nothing recent there is only one group, and a lone header over the
    /// whole list labels nothing.
    public var showsSections: Bool { !recent.isEmpty }

    private let userAPI: UserAPIProtocol
    private let instantAPI: InstantAPIProtocol
    /// Read at load time rather than captured, so the picker reflects whatever
    /// the store last heard from `GET /api/v1/instant/conversations`.
    private let history: @MainActor () -> [InstantConversationSummary]
    private let currentUserId: Int?

    public init(
        userAPI: UserAPIProtocol,
        instantAPI: InstantAPIProtocol,
        history: @escaping @MainActor () -> [InstantConversationSummary],
        currentUserId: Int?
    ) {
        self.userAPI = userAPI
        self.instantAPI = instantAPI
        self.history = history
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
            candidates = Self.ordered(users, history: history())
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
    ///
    /// Recency comes from the conversation history rather than anything held on
    /// the device, so it survives a reinstall and is the same on every device
    /// you sign in from.
    static func ordered(
        _ users: [UserSummary],
        history: [InstantConversationSummary]
    ) -> [Candidate] {
        let lastSeen = Dictionary(
            history.map { ($0.userId, $0.lastInteractionAt) },
            uniquingKeysWith: { first, second in max(first, second) }
        )

        let candidates = users.enumerated().map { position, user in
            (
                position: position,
                candidate: Candidate(
                    user: user,
                    isEnrolled: nil,
                    lastInteractionAt: lastSeen[user.id]
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            switch (lhs.candidate.lastInteractionAt, rhs.candidate.lastInteractionAt) {
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

    /// Re-sorts what is already on screen against newer history.
    ///
    /// The history is fetched, so it can land after the picker has opened.
    /// Rendering in the server's order and then re-sorting beats holding the
    /// list back until it arrives, and keeps whatever enrollment has resolved.
    public func reorder(using history: [InstantConversationSummary]) {
        let enrollment = Dictionary(
            candidates.map { ($0.id, $0.isEnrolled) },
            uniquingKeysWith: { first, _ in first }
        )
        candidates = Self.ordered(candidates.map(\.user), history: history)
            .map { candidate in
                var updated = candidate
                updated.isEnrolled = enrollment[candidate.id] ?? nil
                return updated
            }
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
                // An aim carried in from the camera is ticked before anyone has
                // been checked. Somebody with no device cannot be sent to, and a
                // tick on a disabled row is one that cannot be taken off.
                if !enrolled { selectedIds.remove(id) }
            }
        }
    }
}
#endif

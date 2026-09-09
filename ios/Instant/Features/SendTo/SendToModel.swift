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

        public var id: Int { user.id }
    }

    public private(set) var candidates: [Candidate] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var selectedId: Int?

    private let userAPI: UserAPIProtocol
    private let instantAPI: InstantAPIProtocol
    private let currentUserId: Int?

    public init(userAPI: UserAPIProtocol, instantAPI: InstantAPIProtocol, currentUserId: Int?) {
        self.userAPI = userAPI
        self.instantAPI = instantAPI
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
            candidates = users.map { Candidate(user: $0, isEnrolled: nil) }
            await loadEnrollment(for: users)
        } catch {
            errorMessage = "Could not load your Lounge."
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
            }
        }
    }
}
#endif

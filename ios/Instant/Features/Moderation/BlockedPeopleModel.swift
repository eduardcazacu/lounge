#if canImport(UIKit)
import Foundation
import Observation

@MainActor
@Observable
public final class BlockedPeopleModel {
    public private(set) var blocked: [BlockedUser] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?

    private let api: ModerationAPIProtocol

    public init(api: ModerationAPIProtocol) {
        self.api = api
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            blocked = try await api.blockedUsers()
            hasLoaded = true
        } catch {
            errorMessage = "Couldn't load the people you've blocked."
        }
    }

    /// Removed from the list straight away, and put back if the server says no —
    /// an unblock that looks like it did nothing invites tapping it again.
    public func unblock(_ user: BlockedUser) async {
        guard let index = blocked.firstIndex(of: user) else { return }
        blocked.remove(at: index)
        errorMessage = nil
        do {
            try await api.unblock(userId: user.userId)
        } catch {
            blocked.insert(user, at: min(index, blocked.count))
            errorMessage = "Couldn't unblock \(user.displayName). Try again."
        }
    }
}
#endif

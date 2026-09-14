#if canImport(UIKit)
import Foundation
import Observation

@MainActor
@Observable
public final class DeleteAccountModel {
    public var password = ""
    public private(set) var isDeleting = false
    public private(set) var errorMessage: String?

    private let userAPI: UserAPIProtocol

    public init(userAPI: UserAPIProtocol) {
        self.userAPI = userAPI
    }

    public var canDelete: Bool { !password.isEmpty && !isDeleting }

    /// Returns whether the account is gone. The caller signs out; this only
    /// talks to the server, so a failure leaves everything as it was.
    public func delete() async -> Bool {
        guard canDelete else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await userAPI.deleteAccount(password: password)
            return true
        } catch let error as APIError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = "Couldn't delete your account. Check your connection and try again."
            return false
        }
    }
}
#endif

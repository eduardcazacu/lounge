import Foundation
import Observation

@MainActor
@Observable
public final class SignInModel {
    public var email = ""
    public var password = ""
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    private let userAPI: UserAPIProtocol

    public init(userAPI: UserAPIProtocol) {
        self.userAPI = userAPI
    }

    public var canSubmit: Bool {
        !isSubmitting && email.contains("@") && !password.isEmpty
    }

    /// Returns the access token on success.
    ///
    /// Sign-in rejections are 403 with three distinct messages — wrong
    /// credentials, unverified email, pending admin approval. They are surfaced
    /// verbatim: "your account is pending admin approval" is genuinely useful and
    /// flattening it to "sign-in failed" would leave someone retrying a password
    /// that was never the problem.
    public func submit() async -> String? {
        guard canSubmit else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            return try await userAPI.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        } catch let error as APIError {
            errorMessage = error.message
        } catch {
            errorMessage = "Could not reach Eddie's Lounge. Check your connection."
        }
        return nil
    }
}

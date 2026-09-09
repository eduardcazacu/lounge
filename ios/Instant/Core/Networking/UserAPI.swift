import Foundation

public protocol UserAPIProtocol: Sendable {
    func signIn(email: String, password: String) async throws -> String
    func signOut() async
    func me() async throws -> AccountProfile
    func updateProfile(bio: String, themeKey: String) async throws -> UpdatedProfile
    func uploadProfilePicture(_ data: Data, filename: String, contentType: String) async throws -> String?
    func deleteProfilePicture() async throws
    func setNotificationsEnabled(_ enabled: Bool) async throws -> Bool
    func registerAPNsToken(_ token: String, sandbox: Bool) async throws
    func users() async throws -> [UserSummary]
}

public struct UserAPI: UserAPIProtocol {
    let client: APIClientProtocol
    static let base = "api/v1/user"

    public init(client: APIClientProtocol) {
        self.client = client
    }

    private struct Credentials: Encodable {
        let email: String
        let password: String
    }

    /// Sign-in failures come back as 403 with three distinct messages — bad
    /// credentials, unverified email, pending approval. `authenticated: false`
    /// keeps the client from mistaking those for an expired token and burning a
    /// refresh on them.
    public func signIn(email: String, password: String) async throws -> String {
        let request = APIRequest(
            method: "POST",
            path: "\(Self.base)/signin",
            body: .json(try JSONEncoder().encode(Credentials(email: email, password: password))),
            authenticated: false
        )
        return try await client.decode(SignInResponse.self, from: request).token
    }

    public func signOut() async {
        try? await client.send(APIRequest(method: "POST", path: "\(Self.base)/logout"))
    }

    public func me() async throws -> AccountProfile {
        try await client.decode(MeResponse.self, from: .get("\(Self.base)/me")).user
    }

    private struct ProfileUpdate: Encodable {
        let bio: String
        let themeKey: String
    }

    /// `bio` is not optional in effect: the handler coerces a missing value to
    /// "" and wipes it. Callers must always pass the current text.
    public func updateProfile(bio: String, themeKey: String) async throws -> UpdatedProfile {
        try await client.decode(
            UpdateProfileResponse.self,
            from: .put("\(Self.base)/me", json: ProfileUpdate(bio: bio, themeKey: themeKey))
        ).user
    }

    public func uploadProfilePicture(
        _ data: Data,
        filename: String,
        contentType: String
    ) async throws -> String? {
        let request = APIRequest(
            method: "POST",
            path: "\(Self.base)/me/profile-picture",
            body: .multipart([
                MultipartPart(name: "image", filename: filename, contentType: contentType, data: data)
            ])
        )
        return try await client.decode(ProfilePictureResponse.self, from: request).profilePictureUrl
    }

    public func deleteProfilePicture() async throws {
        try await client.send(.post("\(Self.base)/me/profile-picture/delete"))
    }

    private struct NotificationsUpdate: Encodable { let notificationsEnabled: Bool }

    public func setNotificationsEnabled(_ enabled: Bool) async throws -> Bool {
        try await client.decode(
            NotificationsResponse.self,
            from: .put("\(Self.base)/me/notifications", json: NotificationsUpdate(notificationsEnabled: enabled))
        ).notificationsEnabled
    }

    private struct APNsSubscription: Encodable {
        let endpoint: String
        let provider: String
        let userAgent: String
    }

    /// APNs rows reuse the Web Push subscription table: `endpoint` holds the hex
    /// device token and `provider` distinguishes the two, with the sandbox and
    /// production environments kept apart because the same token is not valid in
    /// both.
    public func registerAPNsToken(_ token: String, sandbox: Bool) async throws {
        try await client.send(
            .post(
                "\(Self.base)/me/push/subscribe",
                json: APNsSubscription(
                    endpoint: token,
                    provider: sandbox ? "apns-sandbox" : "apns",
                    userAgent: "Instant-iOS"
                )
            )
        )
    }

    public func users() async throws -> [UserSummary] {
        try await client.decode(UserListResponse.self, from: .get("\(Self.base)/list")).users
    }
}

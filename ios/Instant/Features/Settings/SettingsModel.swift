#if canImport(UIKit)
import Foundation
import Observation
import UIKit

@MainActor
@Observable
public final class SettingsModel {
    public private(set) var profile: AccountProfile?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var savedAt: Date?

    public var bio = ""
    public var themeKey = ThemePalette.defaultKey
    public var notificationsEnabled = true
    public private(set) var profilePictureUrl: String?

    private let userAPI: UserAPIProtocol
    private let time: TimeSource

    public init(userAPI: UserAPIProtocol, time: TimeSource = .live) {
        self.userAPI = userAPI
        self.time = time
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let profile = try await userAPI.me()
            self.profile = profile
            bio = profile.bio ?? ""
            themeKey = profile.themeKey
            notificationsEnabled = profile.notificationsEnabled
            profilePictureUrl = profile.profilePictureUrl
        } catch {
            errorMessage = "Could not load your account."
        }
    }

    /// `bio` is always sent, even when untouched.
    ///
    /// The handler coerces a missing `bio` to "" and writes it, so omitting the
    /// field to mean "unchanged" silently wipes it. This is the one API in the
    /// Lounge that behaves that way.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let updated = try await userAPI.updateProfile(bio: bio, themeKey: themeKey)
            bio = updated.bio ?? ""
            themeKey = updated.themeKey
            savedAt = time.now()
        } catch let error as APIError {
            errorMessage = error.message
        } catch {
            errorMessage = "Could not save your changes."
        }
    }

    public func setNotifications(_ enabled: Bool) async {
        let previous = notificationsEnabled
        notificationsEnabled = enabled
        do {
            notificationsEnabled = try await userAPI.setNotificationsEnabled(enabled)
        } catch {
            notificationsEnabled = previous
            errorMessage = "Could not change your notification setting."
        }
    }

    public func uploadProfilePicture(_ image: UIImage) async {
        do {
            // Avatars go through the same ladder as instants, just smaller.
            let encoded = try ImagePipeline.encode(
                image,
                options: EncodeOptions(
                    maxWidth: 512,
                    maxHeight: 512,
                    targetBytes: 120_000,
                    qualityLevels: [0.9, 0.8, 0.7],
                    minLongEdge: 256
                )
            )
            profilePictureUrl = try await userAPI.uploadProfilePicture(
                encoded,
                filename: "avatar.webp",
                contentType: "image/webp"
            )
        } catch {
            errorMessage = "Could not upload that picture."
        }
    }

    public func removeProfilePicture() async {
        do {
            try await userAPI.deleteProfilePicture()
            profilePictureUrl = nil
        } catch {
            errorMessage = "Could not remove your picture."
        }
    }
}
#endif

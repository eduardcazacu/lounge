#if canImport(UIKit)
import Foundation
import UIKit
import UserNotifications

/// Asks for notification permission, hands the APNs token to the backend, and
/// routes a tapped notification to the instant it names.
///
/// The payload deliberately carries no photo and no key material — just who sent
/// it and its id. There is nothing useful in an Instant notification beyond
/// "come and look", and the server could not decrypt the image to preview it
/// even if the design wanted that.
@MainActor
public final class PushRegistrar: NSObject {
    private let userAPI: UserAPIProtocol
    private let onOpenInstant: @MainActor (String?) -> Void

    /// Development builds talk to APNs sandbox; TestFlight and App Store builds
    /// talk to production. The same device token is not valid in both, which is
    /// why the backend keeps them apart as separate `provider` values.
    public nonisolated static var isSandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public init(
        userAPI: UserAPIProtocol,
        onOpenInstant: @escaping @MainActor (String?) -> Void
    ) {
        self.userAPI = userAPI
        self.onOpenInstant = onOpenInstant
        super.init()
    }

    /// Push is compiled out unless the `INSTANT_PUSH_ENABLED` build setting is
    /// YES.
    ///
    /// The Push Notifications capability needs the `aps-environment` entitlement,
    /// and a free personal team cannot sign an app that declares it — the build
    /// is refused outright, so the app cannot go on a device at all. Leaving it
    /// off by default keeps `xcodebuild` working for everyone; flip the setting
    /// once there is a paid membership and both the entitlement and this code
    /// come back with no other change.
    ///
    /// Notification *taps* are still handled either way, so a build with push
    /// switched on later needs nothing else.
    public func requestAuthorizationAndRegister() async {
        UNUserNotificationCenter.current().delegate = self
        #if INSTANT_PUSH
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #else
        // Deliberately does not prompt: iOS gives one chance to ask, and asking
        // when no token can be issued spends it for nothing.
        #endif
    }

    public nonisolated static func hexToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public func register(deviceToken: Data) async {
        try? await userAPI.registerAPNsToken(
            Self.hexToken(from: deviceToken),
            sandbox: Self.isSandbox
        )
    }

    /// `data.instantId` is set by the send fallback in `backend/src/route/instant.ts`;
    /// the streak warning has no instant and just opens the app.
    nonisolated static func instantId(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["data"] as? [String: Any])?["instantId"] as? String
    }
}

extension PushRegistrar: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Pull the id out here rather than sending the whole userInfo
        // dictionary across the actor boundary — it is [AnyHashable: Any] and
        // therefore not Sendable.
        let instantId = Self.instantId(from: response.notification.request.content.userInfo)
        await MainActor.run {
            onOpenInstant(instantId)
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif

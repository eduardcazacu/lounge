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
/// The system calls `PushRegistrar` makes, behind a protocol so they can be
/// observed in a test.
@MainActor
public protocol NotificationAuthorizing {
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func registerForRemoteNotifications()
}

public struct SystemNotificationAuthorizer: NotificationAuthorizing {
    public init() {}

    public func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
public final class PushRegistrar: NSObject {
    private let userAPI: UserAPIProtocol
    private let onOpenInstant: @MainActor (String?) -> Void
    /// Injected so a test can assert the prompt is actually requested. The gate
    /// that used to suppress it was invisible to every test precisely because
    /// this call went straight to the system.
    private let notifications: NotificationAuthorizing

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
        notifications: NotificationAuthorizing = SystemNotificationAuthorizer(),
        onOpenInstant: @escaping @MainActor (String?) -> Void
    ) {
        self.userAPI = userAPI
        self.notifications = notifications
        self.onOpenInstant = onOpenInstant
        super.init()
    }

    /// Asks for permission, then registers for a token if it was given.
    ///
    /// This used to be behind an `#if INSTANT_PUSH` that was never defined in
    /// any build configuration, so the prompt was compiled out of every build
    /// and the app could never ask. The gate existed because a free personal
    /// team cannot sign an app declaring `aps-environment`; with a paid
    /// membership that no longer applies, and a compile-time switch that
    /// silently disables a feature is the wrong shape for it regardless.
    ///
    /// `requestAuthorization` is idempotent: once someone has answered, iOS
    /// returns the standing decision without prompting again, so calling this on
    /// every sign-in is safe.
    public func requestAuthorizationAndRegister() async {
        notifications.setDelegate(self)
        let granted = (try? await notifications.requestAuthorization(
            options: [.alert, .sound, .badge]
        )) ?? false
        guard granted else { return }
        notifications.registerForRemoteNotifications()
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

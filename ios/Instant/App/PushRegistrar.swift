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

    /// Starts routing tapped notifications, which is a separate job from asking
    /// for permission and has to happen much earlier.
    ///
    /// iOS hands a notification tapped from a cold start to whatever delegate is
    /// in place when launching finishes, once. Setting this after sign-in — the
    /// old arrangement — was always too late: the tap was dropped and the app
    /// came up on the camera. Permission is irrelevant here; if there was no
    /// permission there would be no notification to tap.
    public func observeTaps() {
        notifications.setDelegate(self)
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

/// Both of these are main-actor isolated, inherited from the class rather than
/// opted out of with `nonisolated` — which is not a style choice.
///
/// Swift turns an `async` delegate method into the `@objc` completion-handler
/// method the system actually calls, and invokes that completion handler on
/// whatever executor the method was isolated to. UIKit's handler for a tapped
/// notification updates the app snapshot and state restoration, and asserts
/// unless it is called on the main thread, so as `nonisolated` every tap ended
/// in
///
///     NSInternalInconsistencyException: Call must be made on main thread
///
/// The app was killed before it could show anything: a cold start came up and
/// died on the spot, and a tap with the app in the background did nothing at
/// all. Hopping to the main actor *inside* the method — the old `MainActor.run`
/// — is too late, because the completion handler is called after it returns.
///
/// `@preconcurrency` on the conformance is what lets an isolated method satisfy
/// a requirement declared without isolation: `UNNotificationResponse` and
/// friends are not `Sendable`, and the main-actor hop the compiler is warning
/// about is the one that has to happen anyway.
extension PushRegistrar: @preconcurrency UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        onOpenInstant(Self.instantId(from: response.notification.request.content.userInfo))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif

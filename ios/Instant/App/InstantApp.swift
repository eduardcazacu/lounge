#if canImport(UIKit)
import SwiftUI
import UIKit

@main
struct InstantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment: AppEnvironment

    init() {
        let environment = LaunchOptions.makeEnvironment()
        _environment = State(initialValue: environment)
        AppDelegate.shared = environment
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
        }
    }
}

/// Only here for APNs — SwiftUI has no scene hook for the device token.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var shared: AppEnvironment?
    @MainActor static var registrar: PushRegistrar?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await Self.registrar?.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on a Simulator with no APNs entitlement, and whenever the
        // device is offline. Nothing to recover: registration is retried on the
        // next launch.
    }
}
#endif

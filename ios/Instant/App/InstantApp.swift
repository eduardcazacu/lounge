#if canImport(UIKit)
import SwiftUI
import UIKit

@main
struct InstantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment: AppEnvironment

    init() {
        // First, so the launch is timed from the process starting rather than
        // from whatever the environment spends before it is built.
        JourneyLog.shared.beginLaunch()
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

/// Only here for APNs — SwiftUI has no scene hook for the device token, and
/// none for being the notification delegate early enough either.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var shared: AppEnvironment? {
        didSet { installRegistrar() }
    }

    @MainActor static var registrar: PushRegistrar?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated { Self.installRegistrar() }
        return true
    }

    /// Claims the `UNUserNotificationCenter` delegate as early as there is an
    /// environment to route into.
    ///
    /// This used to happen after sign-in, several awaits deep — by which time a
    /// notification tapped from a cold start has already been dropped: iOS
    /// delivers that response once, to whatever delegate exists when launching
    /// finishes, and the app came up on the camera with the tap lost. The two
    /// callers race (the `App` initialiser and `didFinishLaunchingWithOptions`,
    /// in whichever order SwiftUI runs them), so whichever has both halves
    /// first wins and the other is a no-op.
    @MainActor static func installRegistrar() {
        guard registrar == nil, let environment = shared else { return }
        let registrar = PushRegistrar(userAPI: environment.userAPI) { [weak environment] instantId, senderName in
            environment?.openInbox(instantId: instantId, senderName: senderName)
        }
        registrar.observeTaps()
        self.registrar = registrar
    }

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

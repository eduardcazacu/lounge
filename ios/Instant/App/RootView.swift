#if canImport(UIKit)
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if environment.session.isSignedIn {
                MainPager()
            } else {
                SignInView()
            }
        }
        .task(id: environment.session.currentUserId) {
            // Both of these are gated on being signed in: asking for
            // notification permission on the sign-in screen spends the one
            // prompt iOS gives you before the person has any reason to say yes.
            guard let userId = environment.session.currentUserId else { return }
            await environment.store.start(userId: userId)
            await registerForPush()
        }
        .onChange(of: environment.store.sessionExpired) { _, expired in
            guard expired else { return }
            Task {
                await environment.signOut()
                environment.store.clearSessionExpired()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background is exactly when a queued instant
            // is most likely waiting, and when the socket most likely died.
            guard phase == .active, environment.session.isSignedIn else { return }
            Task { await environment.store.refreshAll() }
        }
    }

    private func registerForPush() async {
        guard !LaunchOptions.isStubbed else { return }
        let registrar = PushRegistrar(userAPI: environment.userAPI) { instantId in
            environment.pendingInstantId = instantId
            environment.showsInbox = true
        }
        AppDelegate.registrar = registrar
        await registrar.requestAuthorizationAndRegister()
    }
}

/// Snapchat's spine: the camera is the app, and conversations are one swipe
/// away to the *left* of it — which is why the camera's chat button also sits in
/// the bottom-left corner. The two gestures point the same way.
struct MainPager: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        TabView(selection: $environment.showsInbox) {
            InboxScreen().tag(true)
            CameraScreen().tag(false)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .background(InstantStyle.background)
    }
}
#endif

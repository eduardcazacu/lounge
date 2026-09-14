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
            await environment.loadAccount()
            await registerForPush()
        }
        .onChange(of: environment.store.sessionExpired) { _, expired in
            guard expired else { return }
            Task {
                await environment.signOut()
                environment.store.clearSessionExpired()
            }
        }
        // A tapped widget. The notification path comes in through the
        // `UNUserNotificationCenter` delegate instead, and both end up in
        // `openInbox`.
        .onOpenURL { environment.handle($0) }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background is exactly when a queued instant
            // is most likely waiting, and when the socket most likely died.
            guard phase == .active, environment.session.isSignedIn else { return }
            Task { await environment.store.refreshAll() }
        }
    }

    /// Only the permission prompt happens here. Listening for taps is set up at
    /// launch by `AppDelegate`, because a notification tapped from a cold start
    /// is delivered only to a delegate that was already in place.
    private func registerForPush() async {
        guard !LaunchOptions.isStubbed || LaunchOptions.requestsPush else { return }
        await AppDelegate.registrar?.requestAuthorizationAndRegister()
    }
}

/// Snapchat's spine: the camera is the app, and conversations are one swipe
/// away to the *left* of it — which is why the camera's chat button also sits in
/// the bottom-left corner. The two gestures point the same way.
struct MainPager: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        ZStack {
            TabView(selection: $environment.showsInbox) {
                InboxScreen().tag(true)
                CameraScreen().tag(false)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Above the pager rather than on a page: the way into settings
            // should not slide off with whichever page happens to be under it,
            // and the inbox is exactly where somebody is most likely to want it.
            //
            // Not while a photo is being composed, though. Being above the
            // pager puts it above that screen too, in the corner the cross that
            // discards the capture already occupies.
            if !environment.isComposing {
                ViewportOverlay {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            AccountButton()
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: environment.isComposing)
        .background(InstantStyle.background)
    }
}
#endif

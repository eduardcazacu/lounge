#if canImport(UIKit)
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if environment.session.isSignedIn {
                if environment.needsTermsAcceptance {
                    // Instead of the app rather than over it, so nothing behind
                    // it — a tapped notification opening the viewer, say — can
                    // be reached before the guidelines are agreed to.
                    TermsScreen()
                } else {
                    MainPager()
                }
            } else {
                SignInView()
            }
        }
        .task(id: environment.session.currentUserId) {
            // Both of these are gated on being signed in: asking for
            // notification permission on the sign-in screen spends the one
            // prompt iOS gives you before the person has any reason to say yes.
            guard let userId = environment.session.currentUserId else { return }
            // With `storeStarting` and `identityLoaded`, splits the half-second a
            // notification launch spends before its identity into scheduling
            // and Keychain (`wiki/ios-performance.md`).
            JourneyLog.shared.markRunning("rootTaskStarted")
            // Side by side: neither needs the other, and the account is what
            // draws the avatar and decides the terms gate.
            // Anything a force quit left sealed goes now: the session is as
            // ready as it is going to be, and the refresh coordinator covers
            // a token that has aged out.
            environment.outbox.resume()
            async let started: Void = environment.store.start(userId: userId)
            async let account: Void = environment.loadAccount()
            _ = await (started, account)
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
        .onAppear {
            JourneyLog.shared.mark(.launch, "firstFrame")
            JourneyLog.shared.annotate(.launch, [
                "signedIn": String(environment.session.isSignedIn),
                "inboxCached": String(environment.store.hasLoaded),
            ])
            // Nothing is fetched for somebody signed out, so the frame is the end.
            if !environment.session.isSignedIn {
                JourneyLog.shared.end(.launch, outcome: "signedOut")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                environment.outbox.didEnterBackground()
                JourneyLog.shared.didEnterBackground()
            case .active:
                environment.outbox.didBecomeActive()
                // Coming back from the background is exactly when a queued
                // instant is most likely waiting, and when the socket most
                // likely died.
                guard environment.session.isSignedIn else { return }
                // A cold start's first `.active` belongs to the launch, which
                // is timed on its own. Keyed per return, so a refresh that
                // outlives one foreground cannot end the next one's journey.
                let resume = JourneyLog.shared.hasEnteredBackground ? UUID().uuidString : nil
                if let resume { JourneyLog.shared.begin(.resume, key: resume) }
                Task {
                    await environment.store.refreshAll()
                    if let resume { JourneyLog.shared.end(.resume, key: resume) }
                }
            default:
                break
            }
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
                        // Above the pager for the same reason: a send started
                        // from the camera is still worth hearing about after a
                        // swipe to the inbox. It sits over the camera's bottom
                        // bar, clear of the shutter.
                        SendStatusPill()
                            .padding(.bottom, SendStatusPill.bottomClearance)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: environment.isComposing)
        .background(InstantStyle.background)
        .sheet(isPresented: $environment.showsWhatsNew) {
            WhatsNewScreen(notes: environment.whatsNew.notes)
        }
        .task {
            // A beat after the first frame, not on it: a notification tapped
            // from a cold start is not always delivered before the pager
            // appears, and the notes must not cover the photo it opens.
            try? await Task.sleep(for: .milliseconds(600))
            environment.presentWhatsNewIfDue()
        }
    }
}
#endif

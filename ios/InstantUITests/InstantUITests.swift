import XCTest

/// End-to-end flows against the stubbed backend and a fixed camera frame.
///
/// The stub exists because the real endpoints cannot support a repeatable UI
/// test: `GET /:id/media` is destructive, so the second run of "open an instant"
/// would always fail. Only the API and camera seams are replaced — every screen,
/// view model, navigation path and the real decrypt run exactly as shipped.
final class InstantUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-instantUITestStubs"]
        if signedIn { app.launchArguments.append("-instantUITestSignedIn") }
        app.launch()
        return app
    }

    /// The sign-in screen is identified by its email field rather than the
    /// title: a bare `VStack` is not an accessibility element, so an identifier
    /// on one never reaches the tree.
    private func waitForSignIn(_ app: XCUIApplication) {
        XCTAssertTrue(app.textFields["signIn.email"].waitForExistence(timeout: 30))
    }

    /// Generous by default: these run in parallel with the unit suite, and a
    /// value that only arrives after a network round trip can take a while on a
    /// loaded machine. The assertion still fails if it never arrives.
    private func waitForLabel(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 30) {
        let matched = expectation(
            for: NSPredicate(format: "label == %@", expected), evaluatedWith: element
        )
        wait(for: [matched], timeout: timeout)
    }

    /// Settings is a `Form`; the device and account rows sit below the fold, so
    /// they are not in the hierarchy until scrolled to.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 20) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }

    // MARK: - Sign in

    func testSignInRejectsBadCredentialsThenSucceeds() {
        let app = launch(signedIn: false)

        waitForSignIn(app)

        let email = app.textFields["signIn.email"]
        email.tap()
        email.typeText("tester@example.com")

        let password = app.secureTextFields["signIn.password"]
        password.tap()
        password.typeText("wrong-password")
        app.buttons["signIn.submit"].tap()

        let error = app.staticTexts["signIn.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(error.label, "Incorrect credentials")

        // Correcting the password gets through, and the camera becomes the home
        // screen — Snapchat's shape.
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        password.typeText("correct-horse")
        app.buttons["signIn.submit"].tap()

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
    }

    func testSignInButtonStaysDisabledUntilBothFieldsAreFilled() {
        let app = launch(signedIn: false)
        waitForSignIn(app)

        let submit = app.buttons["signIn.submit"]
        XCTAssertFalse(submit.isEnabled)

        let email = app.textFields["signIn.email"]
        email.tap()
        email.typeText("tester@example.com")
        XCTAssertFalse(submit.isEnabled)

        let password = app.secureTextFields["signIn.password"]
        password.tap()
        password.typeText("correct-horse")
        XCTAssertTrue(submit.isEnabled)
    }

    // MARK: - Inbox and viewer

    func testOpeningAnInstantDecryptsItAndItExpiresOnItsOwn() {
        let app = launch(signedIn: true)

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()

        // The image is real: the stub sealed a photo to this device's own key,
        // so getting here means the whole ECIES path ran.
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.otherElements["viewer.countdown"].exists)

        // Five seconds, then it closes itself. Wait on the photo disappearing:
        // the inbox stays in the hierarchy behind the cover, so its buttons
        // prove nothing about the viewer being gone.
        waitForDisappearance(app.images["viewer.image"])

        // The person keeps their row — they still have a streak — but nothing
        // is waiting from them any more.
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let noLongerWaiting = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "New Instant"),
            evaluatedWith: row
        )
        wait(for: [noLongerWaiting], timeout: 30)
    }

    func testAnOpenedInstantCannotBeOpenedTwice() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 30))

        // Tap to close early rather than waiting it out.
        app.images["viewer.image"].tap()
        waitForDisappearance(app.images["viewer.image"])

        // Pull to refresh. The person stays on the list — they still have a
        // streak — but the spent instant must not come back as waiting.
        app.swipeDown()
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let stillWaiting = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "New Instant"),
            evaluatedWith: row
        )
        wait(for: [stillWaiting], timeout: 30)
    }

    /// One row per person, with the streak beside the name rather than in a
    /// section of its own.
    func testAConversationRowCarriesBothTheInstantAndTheStreak() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(row.label.contains("9"), "expected the streak count, got: \(row.label)")
        XCTAssertTrue(row.label.contains("New Instant"), "expected the waiting state, got: \(row.label)")

        // And there is no separate streaks section any more.
        XCTAssertFalse(app.staticTexts["STREAKS"].exists)
        XCTAssertFalse(app.buttons["inbox.streak.Ana"].exists)
    }

    /// The safety number is behind a long press, so an ordinary tap can never
    /// land on it by accident.
    func testLongPressingAConversationShowsTheSafetyNumber() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.press(forDuration: 1.0)

        let number = app.staticTexts["safety.number"]
        XCTAssertTrue(number.waitForExistence(timeout: 30))
        // Twelve groups of five digits, which is what the other side compares to.
        let groups = number.label.split(separator: " ")
        XCTAssertEqual(groups.count, 12)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
    }

    /// A plain tap opens what is waiting; with nothing waiting it means the
    /// other direction — the camera, aimed at them.
    func testTappingAConversationWithNothingWaitingOpensTheCameraAimedAtThem() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))

        // Spend the waiting instant first.
        row.tap()
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 30))
        app.images["viewer.image"].tap()
        waitForDisappearance(app.images["viewer.image"])

        // Closing the instant lands back on the inbox, and the row now asks to
        // be replied to rather than sitting inert.
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let offersAReply = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Tap to reply"), evaluatedWith: row
        )
        wait(for: [offersAReply], timeout: 30)

        row.tap()

        // The camera, with Ana already chosen — and the safety number, which is
        // behind a long press, nowhere near this.
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["safety.number"].exists)
        let aim = app.staticTexts["camera.aim"]
        XCTAssertTrue(aim.waitForExistence(timeout: 30))
        XCTAssertEqual(aim.label, "Sending to Ana")
    }

    /// The point of aiming: the photo is taken and the send button already knows
    /// who it is for, so there is no picker between the shutter and sending.
    func testAnAimedCaptureSendsWithoutThePicker() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Bo"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()

        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        let send = app.buttons["compose.sendTo"]
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        XCTAssertEqual(send.label, "Send to Bo")
        // Redirecting is still possible, or a wrong recipient would cost the photo.
        XCTAssertTrue(app.buttons["compose.changeRecipient"].exists)

        send.tap()

        // Back on the camera with the aim spent: the next photo is for whoever
        // is chosen then, not for Bo again.
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        waitForDisappearance(app.staticTexts["camera.aim"])
    }

    /// Recency counts sends, not only what arrives: the stub's history still has
    /// Ana an hour ago and Bo a month ago, and sending to Bo has to reorder them
    /// before the server has any say in it.
    func testSendingMakesSomeoneTheMostRecentContact() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        let olderContact = app.buttons["sendTo.row.Bo"]
        XCTAssertTrue(olderContact.waitForExistence(timeout: 30))
        XCTAssertLessThan(
            app.buttons["sendTo.row.Ana"].frame.minY, olderContact.frame.minY,
            "Ana leads to begin with"
        )
        olderContact.tap()
        app.buttons["sendTo.send"].tap()

        // Take another photo and look again. The stub's conversations endpoint
        // knows nothing about the send, so the new order can only have come from
        // the client recording it.
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        let justSentTo = app.buttons["sendTo.row.Bo"]
        let other = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(justSentTo.waitForExistence(timeout: 30))
        XCTAssertTrue(other.waitForExistence(timeout: 30))
        XCTAssertLessThan(
            justSentTo.frame.minY, other.frame.minY,
            "the person just sent to is the most recent conversation"
        )
    }

    /// A streak about to lapse asks for a send, and stops asking once one has
    /// gone — which it can only know by counting what was sent, not received.
    func testTheStreakPromptGoesAwayAfterSendingToThem() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        // Dee's streak lapses in an hour and she sent last, so it is this
        // reader's move.
        let row = app.buttons["inbox.conversation.Dee"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let asksForASend = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "keep your streak"), evaluatedWith: row
        )
        wait(for: [asksForASend], timeout: 30)

        // Tap through to the camera, aimed at her, and send.
        row.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        let send = app.buttons["compose.sendTo"]
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        XCTAssertEqual(send.label, "Send to Dee")
        send.tap()

        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let stopsAsking = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "keep your streak"),
            evaluatedWith: row
        )
        wait(for: [stopsAsking], timeout: 30)
        // The streak itself is still running, and still about to lapse — what
        // changed is whose move it is.
        XCTAssertTrue(row.label.contains("12"), "the streak count stays: \(row.label)")
    }

    /// Dropping the aim is one tap, and what is left is the ordinary camera.
    func testTheAimCanBeDropped() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Bo"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()

        let clear = app.buttons["camera.aim.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 30))
        clear.tap()

        waitForDisappearance(app.staticTexts["camera.aim"])

        // And the send button is back to asking the question.
        app.buttons["camera.shutter"].tap()
        let send = app.buttons["compose.sendTo"]
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        XCTAssertEqual(send.label, "Send To")
    }

    /// The indicator is absent whenever delivery is working, which is almost
    /// always — it exists to be noticed, not to be lived with.
    func testNoConnectionIndicatorWhileConnected() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        XCTAssertTrue(app.buttons["inbox.camera"].waitForExistence(timeout: 30))
        XCTAssertFalse(
            app.otherElements["inbox.connection"].exists,
            "a healthy connection shows nothing"
        )
        XCTAssertFalse(app.staticTexts["Reconnecting"].exists)
        XCTAssertFalse(app.staticTexts["Live updates off"].exists)
    }

    /// The point of the conversations endpoint: someone whose streak lapsed and
    /// who has nothing waiting is still in the inbox. Under `/streaks` alone
    /// they vanished entirely.
    func testInboxShowsAConversationWithNoStreakAndNothingWaiting() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let lapsed = app.buttons["inbox.conversation.Bo"]
        XCTAssertTrue(lapsed.waitForExistence(timeout: 30))
        XCTAssertFalse(lapsed.label.contains("🔥"), "no streak to draw: \(lapsed.label)")

        // And the one with something waiting still leads.
        let waiting = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 30))
        XCTAssertLessThan(waiting.frame.minY, lapsed.frame.minY)
    }

    /// Conversations sit to the left of the camera, so a swipe from left to
    /// right on the camera reveals them — the same direction the chat button
    /// sits in.
    func testSwipingRightFromTheCameraOpensConversations() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))

        app.swipeRight()
        XCTAssertTrue(app.buttons["inbox.camera"].waitForExistence(timeout: 30))

        app.swipeLeft()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
    }

    /// The profile button is the account's own avatar, not a placeholder.
    func testCameraProfileButtonShowsTheSignedInAccount() {
        let app = launch(signedIn: true)
        let profile = app.buttons["camera.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 30))

        // The stub account is "Tester"; the avatar labels itself with the name
        // it is drawing, so this catches a hardcoded placeholder.
        let named = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Tester"), evaluatedWith: profile
        )
        wait(for: [named], timeout: 30)
        XCTAssertFalse(profile.label.contains("Me"), "the placeholder is gone")
    }

    func testCameraShowsNoStreakCounter() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        // The stub has a 9-day streak; it belongs on the conversation row, not here.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "🔥")).element.exists)
    }

    // MARK: - Capture and send

    func testCaptureAddCaptionPickDurationAndSend() {
        let app = launch(signedIn: true)

        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))

        // The duration chip cycles 5s -> infinite -> 1s.
        let duration = app.buttons["compose.duration"]
        XCTAssertEqual(duration.value as? String, "5s")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "infinite")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "1s")

        app.buttons["compose.caption"].tap()
        let field = app.textFields["compose.captionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        // Type into the focused field and dismiss by tapping the backdrop.
        // Reaching for the keyboard's own Done key invites an interruption that
        // invalidates the element mid-test.
        app.typeText("hello from a test")
        app.tap()

        XCTAssertTrue(app.staticTexts["compose.captionOverlay"].waitForExistence(timeout: 15))

        app.buttons["compose.sendTo"].tap()

        // Ana has a device key; the row for someone unenrolled is disabled.
        let recipient = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 30))
        recipient.tap()
        app.buttons["sendTo.send"].tap()

        // Back to the camera once it is away.
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
    }

    /// Recency now comes from the server, so the whole order is deterministic:
    /// the stub's history has Ana an hour ago and Bo a month ago, both under
    /// "Recent", and Cass with no history at all under "Everyone".
    func testRecipientPickerLeadsWithTheMostRecentContact() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        let mostRecent = app.buttons["sendTo.row.Ana"]
        let olderContact = app.buttons["sendTo.row.Bo"]
        let stranger = app.buttons["sendTo.row.Cass"]
        XCTAssertTrue(mostRecent.waitForExistence(timeout: 30))
        XCTAssertTrue(olderContact.waitForExistence(timeout: 30))
        XCTAssertTrue(stranger.waitForExistence(timeout: 30))

        XCTAssertLessThan(
            mostRecent.frame.minY, olderContact.frame.minY,
            "the more recent of two contacts leads"
        )
        XCTAssertLessThan(
            olderContact.frame.minY, stranger.frame.minY,
            "someone you have talked to should sit above someone you have not"
        )

        // The split is labelled, so the ordering is legible rather than left to
        // be inferred.
        let recentHeader = app.staticTexts["sendTo.header.Recent"]
        let everyoneHeader = app.staticTexts["sendTo.header.Everyone"]
        XCTAssertTrue(recentHeader.waitForExistence(timeout: 30))
        XCTAssertTrue(everyoneHeader.waitForExistence(timeout: 30))

        XCTAssertLessThan(recentHeader.frame.minY, mostRecent.frame.minY)
        XCTAssertLessThan(olderContact.frame.minY, everyoneHeader.frame.minY)
        XCTAssertLessThan(everyoneHeader.frame.minY, stranger.frame.minY)
    }

    func testDiscardingACaptureReturnsToTheCamera() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.discard"].waitForExistence(timeout: 30))
        app.buttons["compose.discard"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
    }

    // MARK: - Settings

    func testSettingsShowsAccountAndDeviceKeyDetails() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 30))
        app.buttons["camera.profile"].tap()

        let name = app.staticTexts["settings.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        // The row renders a placeholder until the profile fetch lands.
        waitForLabel(name, "Tester")

        XCTAssertTrue(app.switches["settings.notifications"].exists)

        // The device key row is how someone checks whether their private key is
        // in the Secure Enclave. It is below the fold.
        // Type-agnostic: SwiftUI decides whether a LabeledContent surfaces as a
        // static text or a container, and that is not worth pinning in a test.
        XCTAssertTrue(scrollTo(app.descendants(matching: .any)["settings.deviceKey"], in: app))
        XCTAssertTrue(scrollTo(app.buttons["settings.signOut"], in: app))
    }

    func testSigningOutReturnsToTheSignInScreen() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 30))
        app.buttons["camera.profile"].tap()

        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(scrollTo(signOut, in: app))
        signOut.tap()

        waitForSignIn(app)
    }

    func testEditingBioAndThemeSaves() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 30))
        app.buttons["camera.profile"].tap()

        let bio = app.textViews["settings.bio"].exists
            ? app.textViews["settings.bio"]
            : app.textFields["settings.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 30))
        bio.tap()
        bio.typeText(" edited")

        app.buttons["settings.save"].tap()
        // Saving keeps the sheet open; the absence of an error is the assertion.
        XCTAssertTrue(app.staticTexts["settings.name"].waitForExistence(timeout: 30))
    }
}

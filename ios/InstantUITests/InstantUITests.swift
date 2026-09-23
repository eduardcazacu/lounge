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

    private func launch(
        signedIn: Bool,
        termsPending: Bool = false,
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-instantUITestStubs"]
        if signedIn { app.launchArguments.append("-instantUITestSignedIn") }
        if termsPending { app.launchArguments.append("-instantUITestTermsPending") }
        app.launchArguments += arguments
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

    // MARK: - What's new

    func testWhatsNewShowsAfterUpdateAndDismisses() {
        let app = launch(signedIn: true, arguments: ["-instantUITestWhatsNew"])

        XCTAssertTrue(app.staticTexts["whatsNew.title"].waitForExistence(timeout: 30))
        app.buttons["whatsNew.continue"].tap()

        waitForDisappearance(app.staticTexts["whatsNew.title"])
        XCTAssertTrue(app.buttons["camera.shutter"].isHittable)
    }

    func testWhatsNewReopensFromSettings() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 30))
        app.buttons["camera.profile"].tap()
        XCTAssertTrue(app.staticTexts["settings.name"].waitForExistence(timeout: 30))

        let row = app.buttons["settings.whatsNew"]
        XCTAssertTrue(scrollTo(row, in: app))
        row.tap()
        XCTAssertTrue(app.staticTexts["whatsNew.title"].waitForExistence(timeout: 10))

        // Pushed rather than presented, so Continue goes back to Settings
        // instead of closing it.
        app.buttons["whatsNew.continue"].tap()
        waitForDisappearance(app.staticTexts["whatsNew.title"])
        XCTAssertTrue(row.waitForExistence(timeout: 10))
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
        // She has a receipt too — a photo of yours she opened last night — and
        // it must not be what the row says. A row says one thing, and something
        // waiting to be opened beats news about something already read.
        XCTAssertFalse(row.label.contains("Opened"), "the receipt must not outrank what is waiting: \(row.label)")

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

        // Press and hold opens a menu now, with reporting and blocking beside it.
        let menuItem = app.buttons["inbox.menu.safetyNumber"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["inbox.menu.report"].exists)
        XCTAssertTrue(app.buttons["inbox.menu.block"].exists)
        menuItem.tap()

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

        // Recency moves once the server has the send, which the pill confirms.
        XCTAssertTrue(app.staticTexts["sendStatus.sent"].waitForExistence(timeout: 30))

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
        XCTAssertTrue(app.staticTexts["sendStatus.sent"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let stopsAsking = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "keep your streak"),
            evaluatedWith: row
        )
        wait(for: [stopsAsking], timeout: 30)
        // And says what it is waiting on instead: the photo that just went,
        // with nobody having opened it yet.
        let reportsTheSend = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Sent just now"), evaluatedWith: row
        )
        wait(for: [reportsTheSend], timeout: 30)
        // The streak itself is still running, and still about to lapse — what
        // changed is whose move it is.
        XCTAssertTrue(row.label.contains("12"), "the streak count stays: \(row.label)")
    }

    // MARK: - Sending in the background

    /// Aims the camera at Bo, takes a photo and sends it — the shortest way to a
    /// send, shared by the outbox tests.
    private func sendAPhotoToBo(_ app: XCUIApplication) {
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
        send.tap()
    }

    /// The upload takes three seconds here, and the camera is back long before
    /// it finishes: the send carries on under a small spinner, then says so.
    func testSendingReturnsToTheCameraAtOnceAndConfirms() {
        let app = launch(signedIn: true, arguments: ["-instantUITestSlowSend"])
        sendAPhotoToBo(app)

        let sending = app.staticTexts["sendStatus.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        XCTAssertEqual(sending.label, "Sending to Bo…")
        XCTAssertTrue(app.buttons["camera.shutter"].isHittable, "the camera is usable while it sends")

        let sent = app.staticTexts["sendStatus.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 30))
        XCTAssertEqual(sent.label, "Sent to Bo")
        XCTAssertTrue(sent.waitForNonExistence(timeout: 15), "the confirmation goes by itself")
    }

    /// A failure is the one state that stays, and it keeps the photo so trying
    /// again is a tap.
    func testAFailedSendSaysSoAndCanBeRetried() {
        let app = launch(signedIn: true, arguments: ["-instantUITestFailFirstSend"])
        sendAPhotoToBo(app)

        let failed = app.staticTexts["sendStatus.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: 30))
        XCTAssertEqual(failed.label, "Couldn't send to Bo")
        XCTAssertTrue(app.staticTexts["The server is busy. Try again."].exists)

        app.buttons["sendStatus.retry"].tap()

        XCTAssertTrue(app.staticTexts["sendStatus.sent"].waitForExistence(timeout: 30))
        XCTAssertFalse(failed.exists)
    }

    /// Killed mid-upload, the sealed photo is still on disk, and the next launch
    /// sends it without being asked.
    func testAnInstantCutOffByAForceQuitIsSentOnTheNextLaunch() {
        let app = launch(signedIn: true, arguments: ["-instantUITestStallSend"])
        sendAPhotoToBo(app)
        let sending = app.staticTexts["sendStatus.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        // The upload never answers. Killed only once the sealed copy is on disk:
        // before that, a force quit loses the send by design.
        let saved = expectation(for: NSPredicate(format: "value == 'saved'"), evaluatedWith: sending)
        wait(for: [saved], timeout: 30)
        app.terminate()

        // Slow on the way back up, so the resumed send is still going by the
        // time the app has settled enough to be looked at.
        let relaunched = launch(
            signedIn: true,
            arguments: ["-instantUITestKeepOutbox", "-instantUITestSendDelay", "10"]
        )
        let resumed = relaunched.staticTexts["sendStatus.sending"]
        XCTAssertTrue(resumed.waitForExistence(timeout: 10), "picked up without being asked")
        XCTAssertEqual(resumed.label, "Sending to Bo…")
        let sent = relaunched.staticTexts["sendStatus.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 30))
        XCTAssertEqual(sent.label, "Sent to Bo")
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

    /// The account button is drawn above the pager rather than on a page, so the
    /// swipe to the inbox has to leave it exactly where it was — and leave it
    /// working there. Anchoring it to either page is what makes it slide away.
    func testTheAccountButtonStaysPutAcrossTheSwipe() {
        let app = launch(signedIn: true)
        let profile = app.buttons["camera.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 30))
        let onTheCamera = profile.frame

        app.buttons["camera.inbox"].tap()
        XCTAssertTrue(app.buttons["inbox.camera"].waitForExistence(timeout: 30))
        XCTAssertEqual(profile.frame, onTheCamera, "it moved with the page")

        // And it is the way into settings from here too, not just a picture.
        profile.tap()
        XCTAssertTrue(app.staticTexts["settings.name"].waitForExistence(timeout: 30))
    }

    /// The account button is drawn above the pager, which puts it above the
    /// compose screen too — in the same corner as the cross that discards the
    /// capture, covering it. It has to step aside while there is a photo to
    /// decide about.
    func testTheAccountButtonGetsOutOfTheWayWhileComposing() {
        let app = launch(signedIn: true)
        let profile = app.buttons["camera.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 30))

        app.buttons["camera.shutter"].tap()
        let discard = app.buttons["compose.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 30))
        XCTAssertFalse(profile.exists, "it is sitting on the discard button")

        // And it comes back with the camera.
        discard.tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        XCTAssertTrue(profile.waitForExistence(timeout: 30))
    }

    func testCameraShowsNoStreakCounter() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        // The stub has a 9-day streak; it belongs on the conversation row, not here.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "🔥")).element.exists)
    }

    /// The tools for the frame run down the right-hand side, the way the
    /// compose screen's do — the two screens are the same surface.
    func testCameraToolsStackVertically() {
        let app = launch(signedIn: true)

        let flash = app.buttons["camera.flash"]
        let flip = app.buttons["camera.flip"]
        XCTAssertTrue(flash.waitForExistence(timeout: 30))
        XCTAssertTrue(flip.waitForExistence(timeout: 30))

        XCTAssertGreaterThanOrEqual(flip.frame.minY, flash.frame.maxY - 1, "flip sits under flash")
        XCTAssertEqual(flip.frame.midX, flash.frame.midX, accuracy: 1, "on one line down the side")
    }

    /// The gesture every camera app has, and the one that does not cost a reach
    /// into the corner.
    func testDoubleTappingTheFrameFlipsTheCamera() {
        let app = launch(signedIn: true)

        let flip = app.buttons["camera.flip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 30))
        XCTAssertEqual(flip.value as? String, "Front")

        // The middle of the screen is inside the frame and clear of every
        // control on it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()

        // Polled rather than waited on with a predicate expectation: the flip
        // is a real session reconfiguration behind the stub, so the value
        // changes a beat after the tap.
        let deadline = Date().addingTimeInterval(15)
        while flip.value as? String != "Back", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(flip.value as? String, "Back")
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

        // A vertical text field is a text view to XCUITest, and a caption with
        // gestures on it is not always a static text, so both are found by
        // identifier alone.
        let field = app.descendants(matching: .any)["compose.captionField"]
        let captions = app.descendants(matching: .any).matching(identifier: "compose.captionOverlay")
        let styleButton = app.buttons["compose.caption"]
        // Above the editor, which sits in the middle of what the keyboard
        // leaves, and clear of the text button on the right.
        let backdrop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12))

        styleButton.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        // Type into the focused field and dismiss by tapping the backdrop.
        // Reaching for the keyboard's own Done key invites an interruption that
        // invalidates the element mid-test.
        app.typeText("hello from a test")
        backdrop.tap()
        XCTAssertTrue(captions.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(captions.firstMatch.value as? String, "bar")

        // Tapping the caption edits it; the text button then swaps its style.
        captions.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertEqual(styleButton.value as? String, "bar")
        styleButton.tap()
        XCTAssertEqual(styleButton.value as? String, "plate")
        backdrop.tap()
        XCTAssertTrue(captions.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(captions.firstMatch.value as? String, "plate")

        // Anywhere else on the photo starts a second caption.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        app.typeText("and another")
        backdrop.tap()
        XCTAssertTrue(captions.element(boundBy: 1).waitForExistence(timeout: 15))
        XCTAssertEqual(captions.count, 2)

        // Dragged onto the trash, which takes the top of the frame while a
        // caption is held, one of them goes.
        let plate = captions.matching(NSPredicate(format: "value == 'plate'")).firstMatch
        plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.135)),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        XCTAssertTrue(plate.waitForNonExistence(timeout: 5))
        XCTAssertEqual(captions.count, 1)

        app.buttons["compose.sendTo"].tap()

        // Ana has a device key; the row for someone unenrolled is disabled.
        let recipient = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 30))
        recipient.tap()
        app.buttons["sendTo.send"].tap()

        // Back to the camera once it is away.
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
    }

    /// Drawing takes over the screen: the other tools go, the colours and undo
    /// come, and the photo stops taking a tap as the start of a caption.
    func testDrawingHidesTheOtherToolsAndUndoesLineByLine() {
        let app = launch(signedIn: true)

        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))

        let draw = app.buttons["compose.draw"]
        let undo = app.buttons["compose.undo"]
        let drawing = app.descendants(matching: .any)["compose.drawing"]
        XCTAssertTrue(draw.waitForExistence(timeout: 15))
        XCTAssertFalse(undo.exists)
        draw.tap()
        XCTAssertEqual(draw.value as? String, "on")

        XCTAssertTrue(app.buttons["compose.ink.red"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compose.caption"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.filters"].exists)
        XCTAssertFalse(app.buttons["compose.discard"].exists)
        XCTAssertFalse(app.buttons["compose.sendTo"].exists)
        XCTAssertFalse(undo.isEnabled)

        app.buttons["compose.ink.red"].tap()
        XCTAssertTrue(app.buttons["compose.ink.red"].isSelected)

        func stroke(from start: CGVector, to end: CGVector) {
            app.coordinate(withNormalizedOffset: start).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: end)
            )
        }
        stroke(from: CGVector(dx: 0.2, dy: 0.4), to: CGVector(dx: 0.6, dy: 0.5))
        XCTAssertEqual(drawing.value as? String, "1")
        // A tap draws a dot rather than starting a caption.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)).tap()
        XCTAssertEqual(drawing.value as? String, "2")
        XCTAssertFalse(app.descendants(matching: .any)["compose.captionField"].exists)

        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertEqual(drawing.value as? String, "1")

        // Leaving keeps the drawing and brings the tools back.
        draw.tap()
        XCTAssertEqual(draw.value as? String, "off")
        XCTAssertTrue(app.buttons["compose.caption"].waitForExistence(timeout: 5))
        XCTAssertFalse(undo.exists)
        XCTAssertFalse(app.buttons["compose.ink.red"].exists)
        XCTAssertEqual(drawing.value as? String, "1")

        app.buttons["compose.sendTo"].tap()
        let recipient = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 30))
        recipient.tap()
        app.buttons["sendTo.send"].tap()

        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
    }

    /// The look is chosen against the photo, so the strip has to be reachable
    /// from the compose screen and survive being folded away again.
    func testPickingAFilterSticksAndSends() {
        let app = launch(signedIn: true)

        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))

        let filters = app.buttons["compose.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 15))
        XCTAssertEqual(filters.value as? String, "Original")
        filters.tap()

        let mono = app.buttons["compose.filter.mono"]
        XCTAssertTrue(mono.waitForExistence(timeout: 15))
        mono.tap()
        XCTAssertEqual(filters.value as? String, "Mono")

        // Folding the strip away is not un-choosing it.
        filters.tap()
        XCTAssertTrue(mono.waitForNonExistence(timeout: 15))
        XCTAssertEqual(filters.value as? String, "Mono")

        app.buttons["compose.sendTo"].tap()
        let recipient = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 30))
        recipient.tap()
        app.buttons["sendTo.send"].tap()

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

    /// Several people can be ticked, and the button says who they are.
    func testSeveralRecipientsCanBePickedAtOnce() {
        let app = launch(signedIn: true, arguments: ["-instantUITestSlowSend"])
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        let ana = app.buttons["sendTo.row.Ana"]
        let bo = app.buttons["sendTo.row.Bo"]
        XCTAssertTrue(ana.waitForExistence(timeout: 30))
        ana.tap()
        bo.tap()
        XCTAssertTrue(ana.isSelected)
        XCTAssertTrue(bo.isSelected)

        let send = app.buttons["sendTo.send"]
        waitForLabel(send, "Send to Ana and Bo")
        send.tap()

        let sending = app.staticTexts["sendStatus.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        XCTAssertEqual(sending.label, "Sending 2…")
        XCTAssertTrue(app.staticTexts["sendStatus.sent"].waitForExistence(timeout: 30))
    }

    /// "All" sits next to Send, so it asks first. Cancelling leaves the picker
    /// as it was; confirming sends to everyone the stub has enrolled — all four.
    func testSendingToEveryoneAsksFirst() {
        let app = launch(signedIn: true, arguments: ["-instantUITestSlowSend"])
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()
        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        let all = app.buttons["sendTo.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: all)
        wait(for: [enabled], timeout: 30)

        all.tap()
        let confirmation = app.alerts["Send to everyone?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(
            confirmation.staticTexts["This photo will go to all 4 people who have Instant set up."].exists
        )
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 10))
        XCTAssertTrue(all.exists, "a cancelled confirmation leaves the picker open")
        XCTAssertFalse(app.staticTexts["sendStatus.sending"].exists, "and sends nothing")

        all.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Send to All"].tap()

        let sending = app.staticTexts["sendStatus.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        XCTAssertEqual(sending.label, "Sending 4…")
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
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

    // MARK: - Video

    /// A tap is a photo and a hold is a clip; both go through one gesture on
    /// the shutter, so both are driven here.
    func testHoldingTheShutterRecordsAClipThatPlaysOnceOrLoops() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.press(forDuration: 1.2)

        // The stand-in camera writes a real clip, which compose plays.
        let clip = app.descendants(matching: .any)["compose.video"]
        XCTAssertTrue(clip.waitForExistence(timeout: 30))
        XCTAssertFalse(app.images["compose.preview"].exists)

        // Once and loop instead of 1s, 5s and ∞.
        let duration = app.buttons["compose.duration"]
        XCTAssertEqual(duration.value as? String, "once")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "loop")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "once")

        // Sound on by default, and off takes it out of what is sent.
        let sound = app.buttons["compose.sound"]
        XCTAssertEqual(sound.value as? String, "on")
        sound.tap()
        XCTAssertEqual(sound.value as? String, "off")

        // The same tools as a photo.
        XCTAssertTrue(app.buttons["compose.caption"].exists)
        XCTAssertTrue(app.buttons["compose.draw"].exists)
        XCTAssertTrue(app.buttons["compose.filters"].exists)
        XCTAssertFalse(app.buttons["compose.parallax"].exists, "a clip already moves")

        app.buttons["compose.discard"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))

        // And a tap is still a photo.
        shutter.tap()
        XCTAssertTrue(app.images["compose.preview"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons["compose.duration"].value as? String, "5s")
        XCTAssertFalse(app.buttons["compose.sound"].exists, "a photo has no sound to turn off")
    }

    /// The depth estimate and the render behind the button are the real ones,
    /// on the Simulator's CPU.
    func testThe3DButtonTurnsAPhotoIntoALoopingClipAndBack() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        shutter.tap()

        XCTAssertTrue(app.images["compose.preview"].waitForExistence(timeout: 30))
        let threeD = app.buttons["compose.parallax"]
        XCTAssertTrue(threeD.waitForExistence(timeout: 10))
        XCTAssertEqual(threeD.value as? String, "off")
        threeD.tap()

        // The render is real, and the Simulator is slow at it.
        let clip = app.descendants(matching: .any)["compose.video"]
        XCTAssertTrue(clip.waitForExistence(timeout: 60))
        XCTAssertEqual(threeD.value as? String, "on")
        XCTAssertEqual(app.buttons["compose.duration"].value as? String, "once", "it plays like a clip")
        XCTAssertFalse(app.buttons["compose.sound"].exists, "four stills have no sound")

        threeD.tap()
        XCTAssertTrue(app.images["compose.preview"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["compose.duration"].value as? String, "5s")
    }

    func testARecordedClipSends() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        // Aimed first, so Send goes straight to the outbox.
        app.buttons["camera.inbox"].tap()
        let row = app.buttons["inbox.conversation.Bo"]
        // The first inbox load on a Simulator takes most of half a minute,
        // on main as well, so this waits longer than the photo tests do.
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))

        shutter.press(forDuration: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["compose.video"].waitForExistence(timeout: 30))
        app.buttons["compose.sendTo"].tap()

        // Encoded, sealed and uploaded after compose has closed, like a photo.
        let sent = app.staticTexts["sendStatus.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 60))
        XCTAssertEqual(sent.label, "Sent to Bo")
    }

    /// The stub seals a real HEVC clip to this device, so this is the whole
    /// path: decrypt, play from memory, and close when a play-once clip ends.
    func testOpeningAClipPlaysItAndItClosesAtTheEnd() {
        let app = launch(signedIn: true, arguments: ["-instantUITestVideoInstant"])

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()
        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        // The row is there from the history before the clip is: the stub
        // encodes it for real, and a row tapped with nothing waiting opens the
        // camera instead.
        let waiting = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "New Instant"), evaluatedWith: row
        )
        wait(for: [waiting], timeout: 60)
        row.tap()

        // A player layer is no particular kind of element, so by identifier.
        let video = app.descendants(matching: .any)["viewer.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        // Quickly, and the tap first: the clip is five seconds long, and every
        // query here costs a fraction of that.
        let mute = app.buttons["viewer.mute"]
        mute.tap()
        XCTAssertEqual(mute.label, "Turn sound off")
        XCTAssertTrue(app.otherElements["viewer.countdown"].exists)

        // A clip that plays once closes itself at its end.
        waitForDisappearance(video)
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

    // MARK: - App Store: guidelines, reporting, blocking, deleting

    /// Guideline 1.2. Nothing past this screen until it has been agreed to.
    func testTheCommunityGuidelinesMustBeAgreedToFirst() {
        let app = launch(signedIn: true, termsPending: true)

        XCTAssertTrue(app.staticTexts["terms.title"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["camera.shutter"].exists)

        app.buttons["terms.agree"].tap()

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["terms.title"].exists)
    }

    func testReportingAPhotoClosesItAndBlocksTheSender() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 30))

        // Five seconds on the clock: opening the report has to hold it, or the
        // photo would close underneath the sheet.
        app.buttons["viewer.more"].tap()
        let send = app.buttons["report.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        XCTAssertFalse(send.isEnabled, "no reason chosen yet")
        XCTAssertTrue(app.switches["report.includePhoto"].exists)

        sleep(6)
        app.buttons["report.reason.harassment"].tap()
        XCTAssertTrue(send.isEnabled)
        send.tap()

        // Closed, and Ana is gone because reporting blocks by default.
        waitForDisappearance(app.images["viewer.image"])
        waitForDisappearance(row)
    }

    func testBlockingFromTheInboxAndUnblockingFromSettings() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Bo"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.press(forDuration: 1.0)
        let block = app.buttons["inbox.menu.block"]
        XCTAssertTrue(block.waitForExistence(timeout: 15))
        block.tap()

        // A confirmation dialog surfaces its buttons twice in the tree.
        let confirm = app.buttons["inbox.block.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        waitForDisappearance(row)

        app.buttons["camera.profile"].tap()
        let blocked = app.buttons["settings.blocked"]
        XCTAssertTrue(scrollTo(blocked, in: app))
        blocked.tap()

        let unblock = app.buttons["blocked.unblock.Bo"]
        XCTAssertTrue(unblock.waitForExistence(timeout: 30))
        unblock.tap()
        XCTAssertTrue(app.staticTexts["blocked.empty"].waitForExistence(timeout: 30))
    }

    /// Guideline 5.1.1(v). A wrong password stays on the sheet; the right one
    /// ends at sign-in.
    func testDeletingTheAccountReturnsToSignIn() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 30))
        app.buttons["camera.profile"].tap()

        let delete = app.buttons["settings.deleteAccount"]
        XCTAssertTrue(scrollTo(delete, in: app))
        delete.tap()

        let password = app.secureTextFields["deleteAccount.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        password.typeText("wrong")
        app.buttons["deleteAccount.submit"].tap()
        let confirm = app.buttons["deleteAccount.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["deleteAccount.error"].waitForExistence(timeout: 15))

        // A secure field offers no Select All; deleting past the start is harmless.
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        password.typeText("correct-horse")
        app.buttons["deleteAccount.submit"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()

        waitForSignIn(app)
    }
}

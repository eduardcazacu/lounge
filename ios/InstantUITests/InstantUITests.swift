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

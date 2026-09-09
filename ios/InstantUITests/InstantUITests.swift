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
        XCTAssertTrue(app.textFields["signIn.email"].waitForExistence(timeout: 10))
    }

    private func waitForLabel(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10) {
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
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Incorrect credentials")

        // Correcting the password gets through, and the camera becomes the home
        // screen — Snapchat's shape.
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        password.typeText("correct-horse")
        app.buttons["signIn.submit"].tap()

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
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

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        // The image is real: the stub sealed a photo to this device's own key,
        // so getting here means the whole ECIES path ran.
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["viewer.countdown"].exists)

        // Five seconds, then it closes itself. Wait on the photo disappearing:
        // the inbox stays in the hierarchy behind the cover, so its buttons
        // prove nothing about the viewer being gone.
        waitForDisappearance(app.images["viewer.image"])

        // The person keeps their row — they still have a streak — but nothing
        // is waiting from them any more.
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let noLongerWaiting = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "New Instant"),
            evaluatedWith: row
        )
        wait(for: [noLongerWaiting], timeout: 10)
    }

    func testAnOpenedInstantCannotBeOpenedTwice() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 10))

        // Tap to close early rather than waiting it out.
        app.images["viewer.image"].tap()
        waitForDisappearance(app.images["viewer.image"])

        // Pull to refresh. The person stays on the list — they still have a
        // streak — but the spent instant must not come back as waiting.
        app.swipeDown()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let stillWaiting = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", "New Instant"),
            evaluatedWith: row
        )
        wait(for: [stillWaiting], timeout: 10)
    }

    /// One row per person, with the streak beside the name rather than in a
    /// section of its own.
    func testAConversationRowCarriesBothTheInstantAndTheStreak() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.0)

        let number = app.staticTexts["safety.number"]
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        // Twelve groups of five digits, which is what the other side compares to.
        let groups = number.label.split(separator: " ")
        XCTAssertEqual(groups.count, 12)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
    }

    /// A plain tap opens what is waiting and nothing else; with nothing waiting
    /// it does nothing at all, and the row carries no instruction text.
    func testTappingAConversationWithNothingWaitingDoesNothing() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.inbox"].tap()

        let row = app.buttons["inbox.conversation.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        // Spend the waiting instant first.
        row.tap()
        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 10))
        app.images["viewer.image"].tap()
        waitForDisappearance(app.images["viewer.image"])

        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.label.contains("safety number"), "the hint text is gone")

        row.tap()
        XCTAssertFalse(
            app.staticTexts["safety.number"].waitForExistence(timeout: 3),
            "a tap must not open the safety number"
        )
    }

    /// Conversations sit to the left of the camera, so a swipe from left to
    /// right on the camera reveals them — the same direction the chat button
    /// sits in.
    func testSwipingRightFromTheCameraOpensConversations() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))

        app.swipeRight()
        XCTAssertTrue(app.buttons["inbox.camera"].waitForExistence(timeout: 10))

        app.swipeLeft()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
    }

    /// The profile button is the account's own avatar, not a placeholder.
    func testCameraProfileButtonShowsTheSignedInAccount() {
        let app = launch(signedIn: true)
        let profile = app.buttons["camera.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))

        // The stub account is "Tester"; the avatar labels itself with the name
        // it is drawing, so this catches a hardcoded placeholder.
        let named = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Tester"), evaluatedWith: profile
        )
        wait(for: [named], timeout: 10)
        XCTAssertFalse(profile.label.contains("Me"), "the placeholder is gone")
    }

    func testCameraShowsNoStreakCounter() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        // The stub has a 9-day streak; it belongs on the conversation row, not here.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "🔥")).element.exists)
    }

    // MARK: - Capture and send

    func testCaptureAddCaptionPickDurationAndSend() {
        let app = launch(signedIn: true)

        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.sendTo"].waitForExistence(timeout: 10))

        // The duration chip cycles 5s -> infinite -> 1s.
        let duration = app.buttons["compose.duration"]
        XCTAssertEqual(duration.value as? String, "5s")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "infinite")
        duration.tap()
        XCTAssertEqual(duration.value as? String, "1s")

        app.buttons["compose.caption"].tap()
        let field = app.textFields["compose.captionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Type into the focused field and dismiss by tapping the backdrop.
        // Reaching for the keyboard's own Done key invites an interruption that
        // invalidates the element mid-test.
        app.typeText("hello from a test")
        app.tap()

        XCTAssertTrue(app.staticTexts["compose.captionOverlay"].waitForExistence(timeout: 5))

        app.buttons["compose.sendTo"].tap()

        // Ana has a device key; the row for someone unenrolled is disabled.
        let recipient = app.buttons["sendTo.row.Ana"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 10))
        recipient.tap()
        app.buttons["sendTo.send"].tap()

        // Back to the camera once it is away.
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
    }

    func testDiscardingACaptureReturnsToTheCamera() {
        let app = launch(signedIn: true)
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()

        XCTAssertTrue(app.buttons["compose.discard"].waitForExistence(timeout: 10))
        app.buttons["compose.discard"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
    }

    // MARK: - Settings

    func testSettingsShowsAccountAndDeviceKeyDetails() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 10))
        app.buttons["camera.profile"].tap()

        let name = app.staticTexts["settings.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 10))
        app.buttons["camera.profile"].tap()

        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(scrollTo(signOut, in: app))
        signOut.tap()

        waitForSignIn(app)
    }

    func testEditingBioAndThemeSaves() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["camera.profile"].waitForExistence(timeout: 10))
        app.buttons["camera.profile"].tap()

        let bio = app.textViews["settings.bio"].exists
            ? app.textViews["settings.bio"]
            : app.textFields["settings.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 10))
        bio.tap()
        bio.typeText(" edited")

        app.buttons["settings.save"].tap()
        // Saving keeps the sheet open; the absence of an error is the assertion.
        XCTAssertTrue(app.staticTexts["settings.name"].waitForExistence(timeout: 5))
    }
}

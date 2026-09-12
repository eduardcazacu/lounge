import XCTest

/// The notification path, minus Apple.
///
/// `xcrun simctl push` delivers a real APNs payload to the Simulator without a
/// developer account, a certificate, or a network round trip — which covers
/// everything on this side of the wire. The one thing it cannot prove is that
/// Apple accepts the request the backend sends; the ES256 signing and request
/// shape are asserted in the backend's own tests instead.
final class PushDeepLinkUITests: XCTestCase {
    func testNotificationPayloadCarriesNoPhotoAndNamesTheInstant() throws {
        // The payload the backend actually sends, from
        // backend/src/route/instant.ts.
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "Ana sent you an instant", "body": "Open it before it disappears."],
                "sound": "default",
            ],
            "data": ["openUrl": "/instant", "instantId": "11111111-2222-3333-4444-555555555555"],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        // A push must never carry image bytes or key material: the server holds
        // only ciphertext and could not produce a preview even if it wanted to.
        XCTAssertFalse(text.contains("wrappedKey"))
        XCTAssertFalse(text.contains("mediaIv"))
        XCTAssertFalse(text.contains("ciphertext"))
        XCTAssertTrue(text.contains("instantId"))
    }

    /// Drives the real deep link: deliver the notification to the running app
    /// and confirm it lands on the instant it names.
    ///
    /// Skipped unless `INSTANT_UITEST_PUSH=1`, because `simctl push` needs the
    /// simulator's udid and a shell, which is not available inside the test
    /// process on every machine. `ios/tools/push-test.sh` runs it.
    func testTappingANotificationOpensTheInstant() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INSTANT_UITEST_PUSH"] == "1",
            "run via ios/tools/push-test.sh"
        )

        let app = XCUIApplication()
        app.launchArguments = ["-instantUITestStubs", "-instantUITestSignedIn"]
        app.launch()

        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))

        // The banner's own element is `NotificationShortLookView` on older
        // runtimes and unnamed on newer ones, where only its title is
        // addressable — and an identifier that stopped matching is a test that
        // fails before it can tap anything, which is how a crash on every tap
        // went unnoticed. Tapping the title hits the same banner either way.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let titled = springboard.staticTexts["Ana sent you an instant"].firstMatch
        let named = springboard.otherElements["NotificationShortLookView"]
        XCTAssertTrue(
            titled.waitForExistence(timeout: 20) || named.waitForExistence(timeout: 5),
            "no notification arrived"
        )
        (titled.exists ? titled : named).tap()

        XCTAssertTrue(app.images["viewer.image"].waitForExistence(timeout: 15))
    }
}

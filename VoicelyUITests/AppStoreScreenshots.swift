import XCTest

// Screenshots come from the iPhone and iPad simulators; XCUIDevice has no
// hardware buttons on Mac Catalyst, where this would not compile.
#if !targetEnvironment(macCatalyst)

/// Captures App Store screenshots from the invented demo library
/// (scripts/demo-library). Skipped unless the runner gets an output folder
/// and the demo library:
///
///   TEST_RUNNER_VOICELY_SCREENSHOT_DIR=<out> TEST_RUNNER_VOICELY_DEMO_DIR=<library> \
///   xcodebuild test -scheme Voicely -destination '<simulator>' \
///     -only-testing:VoicelyUITests/AppStoreScreenshots
///
/// Set the simulator's status bar, locale and appearance before running.
final class AppStoreScreenshots: XCTestCase {
    private var outputDirectory: URL!
    private var demoDirectory: String!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["VOICELY_SCREENSHOT_DIR"], let demo = environment["VOICELY_DEMO_DIR"] else {
            throw XCTSkip("Set VOICELY_SCREENSHOT_DIR and VOICELY_DEMO_DIR to capture screenshots.")
        }
        outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
        demoDirectory = demo
        continueAfterFailure = false
    }

    func testCaptureScreenshots() throws {
        var app = launch()
        save("1-library")

        app = launch()
        openNote("Product Sync", in: app)
        let body = app.descendants(matching: .any)["TranscriptionBody"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        // Tap a sentence near the top: playback starts there and highlights it.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.12)).tap()
        sleep(2)
        save("2-transcript")

        app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Timer'")).firstMatch.tap()
        sleep(2)
        save("4-timer")

        // The recording Live Activity on the Lock Screen. Locking uses
        // XCUIDevice's private lock button, which simulators answer to.
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { return }
        app = launch(extra: [
            "VOICELY_SHOW_RECORDING_ACTIVITY_PREVIEW": "1",
            "VOICELY_LIVE_ACTIVITY_PREVIEW_TITLE": "Product Sync",
            "VOICELY_LIVE_ACTIVITY_PREVIEW_ELAPSED_SECONDS": "1965",
        ])
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(2)
        // A press wakes the screen to the Lock Screen without unlocking it.
        XCUIDevice.shared.perform(lock)
        sleep(3)
        // The first Live Activities ask for permission on the Lock Screen.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Always Allow", "Allow"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            sleep(2)
        }
        save("3-lockscreen")
        XCUIDevice.shared.press(.home)
    }

    /// Captures every shot listed in the JSON file at VOICELY_SHOT_PLAN:
    /// [{"name", "language", "script", "landscape", "wait", "env": {...}}].
    func testCapturePlan() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICELY_SHOT_PLAN"] else {
            throw XCTSkip("Set VOICELY_SHOT_PLAN to capture a plan.")
        }
        struct Shot: Decodable {
            var name: String
            var language: String
            var script: String
            var landscape: Bool?
            var wait: UInt32?
            var env: [String: String]?
        }
        let shots = try JSONDecoder().decode([Shot].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for shot in shots {
            XCUIDevice.shared.orientation = shot.landscape == true ? .landscapeLeft : .portrait
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(\(shot.language))", "-chineseScript", shot.script]
            app.launchEnvironment = ["VOICELY_DEMO_DIR": demoDirectory].merging(shot.env ?? [:]) { _, new in new }
            app.terminate()
            app.launch()
            sleep(shot.wait ?? 6)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try data.write(to: outputDirectory.appendingPathComponent("\(shot.name).png"))
        }
    }

    /// The recording Live Activity on the Lock Screen, in the language and
    /// with the title given by VOICELY_SHOT_LANGUAGE and VOICELY_SHOT_TITLE.
    func testCaptureLockScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        let language = environment["VOICELY_SHOT_LANGUAGE"] ?? "en"
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))"]
        app.launchEnvironment["VOICELY_DEMO_DIR"] = demoDirectory
        app.launchEnvironment["VOICELY_SHOW_RECORDING_ACTIVITY_PREVIEW"] = "1"
        app.launchEnvironment["VOICELY_LIVE_ACTIVITY_PREVIEW_TITLE"] = environment["VOICELY_SHOT_TITLE"] ?? "Q4 Roadmap Review"
        app.launchEnvironment["VOICELY_LIVE_ACTIVITY_PREVIEW_ELAPSED_SECONDS"] = "2745"
        app.launch()
        sleep(10)
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("No lock button on this device.") }
        XCUIDevice.shared.perform(lock)
        sleep(3)
        XCUIDevice.shared.perform(lock)
        sleep(6)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Always Allow", "Allow", "始终允许", "允许", "永遠允許", "允許"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            sleep(2)
        }
        save("lockscreen-\(language)")
        XCUIDevice.shared.press(.home)
    }

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VOICELY_DEMO_DIR"] = demoDirectory
        app.launchEnvironment.merge(extra) { _, new in new }
        // A launch now and then comes up without the demo library; another one fixes it.
        for _ in 0..<3 {
            app.terminate()
            app.launch()
            if row("Product Sync", in: app).waitForExistence(timeout: 10) {
                sleep(1)
                return app
            }
        }
        try? app.debugDescription.write(
            to: outputDirectory.appendingPathComponent("hierarchy.txt"), atomically: true, encoding: .utf8)
        XCTFail("The demo library did not show up.")
        return app
    }

    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    private func openNote(_ title: String, in app: XCUIApplication) {
        row(title, in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["NoteDetailScreen"].firstMatch.waitForExistence(timeout: 10))
        sleep(1)
    }

    private func save(_ name: String) {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = outputDirectory.appendingPathComponent("\(idiom)-\(name).png")
        XCTAssertNoThrow(try data.write(to: url))
    }
}

#endif

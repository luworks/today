import XCTest

/// Alarms claim 7: an item marked "Ring as alarm" rings as a system alarm (AlarmKit) at its time.
/// Slow (waits for the alarm), so it is its own test case.
@MainActor
final class AlarmTests: XCTestCase {
  func testRingAsAlarmFires() throws {
    #if targetEnvironment(simulator)
      // The simulator answers AlarmKit's authorization request with .denied, so this only runs on a device.
      throw XCTSkip("AlarmKit alarms only ring on a real device")
    #else
      let app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      app.launch()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

      // A task two minutes from now.
      let fire = Date.now.addingTimeInterval(120)
      let fmt = DateFormatter()
      fmt.locale = Locale(identifier: "en_US_POSIX")
      fmt.dateFormat = "h:mma"
      let title = "Alarm check"
      app.buttons["Ask AI or add anything"].tap()
      let field =
        app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.typeText("\(title) \(fmt.string(from: fire).lowercased())\n")
      XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
      app.buttons["Add"].tap()
      app.buttons["Close"].tap()

      // Turn on Ring as alarm in the editor.
      let row = app.staticTexts[title]
      XCTAssertTrue(row.waitForExistence(timeout: 5))
      row.tap()
      let ring = app.switches["Ring as alarm"]
      for _ in 0..<4 where !ring.isHittable { app.swipeUp() }
      XCTAssertTrue(ring.waitForExistence(timeout: 5))
      ring.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      XCTAssertEqual(ring.value as? String, "1", "Ring as alarm is on")
      app.buttons["Done"].tap()

      // Allow alarms if asked.
      let allow = springboard.buttons["Allow"]
      if allow.waitForExistence(timeout: 8) { allow.tap() }

      // The alarm should take over the screen at its time.
      let rang =
        springboard.staticTexts[title].waitForExistence(timeout: 200)
        || springboard.otherElements.containing(NSPredicate(format: "label CONTAINS %@", title))
          .firstMatch.exists
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.lifetime = .keepAlways
      add(shot)
      XCTAssertTrue(rang, "alarm UI with the task title appeared")
    #endif
  }
}

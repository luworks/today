import XCTest

/// Today's local editor closes on Done even without edits; Ask moves an Apple event with Undo.
/// (Apple events open in Apple's own Edit Event, covered by `SystemEventEditorTests`.)
@MainActor
final class EventSaveTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  private func calendar(_ app: XCUIApplication) {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.month"].tap()
  }

  private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH %@", title)
    ).firstMatch
  }

  func testAskAIMovesAllDaySystemEventAndUndoes() {
    let title = "Ask event \(UUID().uuidString.prefix(8))"
    let app = XCUIApplication()
    let base =
      TestData.fixtureArguments("event-save.json") + [
        "-uiTestingCalendarSync", "-uiTestingCalendarSaveAllDay", "-appearance", "dark",
      ]
    app.launchArguments = base
    app.launch()
    enableCalendarSync(app)
    app.terminate()
    addTeardownBlock {
      app.terminate()
      app.launchArguments = base + ["-debugDeleteSystemEvent", title]
      app.launch()
      XCTAssertTrue(app.buttons["Calendar"].firstMatch.waitForExistence(timeout: 10))
    }
    app.launchArguments = base + ["-debugCreateSystemEvent", title]
    app.launch()
    calendar(app)
    let event = row(app, title)
    XCTAssertTrue(event.waitForExistence(timeout: 15))
    event.press(forDuration: 1.0)
    let ask = app.buttons["Ask AI"].firstMatch
    XCTAssertTrue(ask.waitForExistence(timeout: 5))
    ask.tap()
    let input = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Move it to tomorrow at 11am")
    app.buttons["ask-send"].tap()
    // No attendees: the move is applied right after the reply, with Undo (owner decision 2026-11-02).
    XCTAssertTrue(app.staticTexts["The calendar event was moved."].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Which item do you mean?"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any)["change-card"].exists, "nothing waits for Apply")
    let undo = app.buttons["ask-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5))
    undo.tap()
    XCTAssertTrue(app.staticTexts["The event was restored."].waitForExistence(timeout: 15))
  }

  func testExistingLocalEventUnchangedSaveCloses() {
    let app = XCUIApplication()
    app.launchArguments = TestData.fixtureArguments("event-save.json")
    app.launch()
    calendar(app)
    let event = row(app, "Local save fixture")
    XCTAssertTrue(event.waitForExistence(timeout: 5))
    event.tap()
    XCTAssertTrue(app.textFields["event.title"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.textFields["event.title"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["calendar.mode.month"].isHittable)
    event.tap()
    XCTAssertEqual(app.textFields["event.title"].value as? String, "Local save fixture")
  }
}

import XCTest

/// "Tidy overdue" on the AI page: a new date per overdue reminder, applied right after the reply with Undo (owner
/// decision 2026-11-02). The dataset has two overdue reminders: "Pay studio invoice" (yesterday 17:00) and "Renew
/// parking permit" (3 days ago, planned for today); both go on today (up to three a day).
@MainActor
final class TidyOverdueTests: XCTestCase {
  func testTidyOverdueMovesTheDateOnlyOnApplyAndUndoBringsItBack() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = TestData.launchArguments
    app.launch()
    let overdueRow = app.buttons.containing(NSPredicate(format: "label CONTAINS '2 overdue'"))
      .firstMatch
    XCTAssertTrue(
      overdueRow.waitForExistence(timeout: 10), "Today starts with two overdue reminders")

    // Tidy applies at once, then Undo on the same page: the old dates are back.
    app.buttons["Ask AI or add anything"].tap()
    sendTidy(app)
    XCTAssertTrue(app.staticTexts["Moved 2 reminders."].firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["tidy.apply"].exists, "nothing waits for Apply")
    let undo = app.buttons["ask-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5), "with Undo")
    undo.tap()
    XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
    app.buttons["Close"].firstMatch.tap()
    XCTAssertTrue(overdueRow.waitForExistence(timeout: 5), "Undo puts the old dates back")

    // Tidy and keep it.
    app.buttons["Ask AI or add anything"].tap()
    sendTidy(app)
    XCTAssertTrue(app.staticTexts["Moved 2 reminders."].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Close"].firstMatch.tap()
    XCTAssertTrue(overdueRow.waitForNonExistence(timeout: 5), "no longer overdue after Tidy")
    app.buttons["Ask AI or add anything"].tap()
    sendTidy(app)
    XCTAssertTrue(app.staticTexts["Nothing is overdue."].firstMatch.waitForExistence(timeout: 5))
  }

  /// The suggestion chips change with the data (no chip once nothing is overdue), so the sentence is typed.
  private func sendTidy(_ app: XCUIApplication) {
    let field =
      app.textViews["Ask AI or add anything"].firstMatch.exists
      ? app.textViews["Ask AI or add anything"].firstMatch : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Tidy overdue\n")
  }
}

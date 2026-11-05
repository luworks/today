import XCTest

/// A past day shows what was actually done on it, rebuilt from Activity (`-uiTestingPastDay` seeds yesterday; see
/// `LaunchTestConfiguration.seedPastDayForTests`): completed reminders, stopped alarms and an event deleted after it
/// happened, while a reminder that was not done stays open and overdue.
@MainActor
final class PastDayHistoryTests: XCTestCase {
  private var app: XCUIApplication!

  private func launch(appearance: String = "light") {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments =
      TestData.launchArguments + [
        "-uiTestingPastDay", "-uiTestingNow", "12:00", "-appearance", appearance,
        "-uiTestingPrefs", "showFreeTime=0",
      ]
    app.launch()
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 10), "Today loaded")
  }

  /// Calendar → 2 Day opens on today and tomorrow; one drag across the grid moves back a day, and tapping yesterday's
  /// column header opens it in Today (as `HealthReviewTests` does for tomorrow). The week strip is not used: on the first
  /// day of a week yesterday sits off screen in it.
  private func openYesterday() {
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.twoday"].tap()
    let header = app.buttons[yesterday.formatted(date: .complete, time: .omitted)].firstMatch
    XCTAssertTrue(header.waitForExistence(timeout: 5))
    let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.55))
    middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 180, dy: 0)))
    sleep(1)
    header.tap()
    XCTAssertTrue(app.weekStripDay(yesterday).waitForSelected())
  }

  private func historyRow(_ prefix: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'today.history.row' AND label BEGINSWITH %@", prefix)
    ).firstMatch
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<4 where !element.exists { app.swipeDown() }
    for _ in 0..<6 where !element.exists { app.swipeUp() }
  }

  private func shoot(_ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testYesterdayShowsWhatWasDone() {
    launch()
    openYesterday()
    for prefix in [
      "Old alarm, Alarm stopped", "Return library books, Marked complete",
      "Team lunch, Scheduled · Source deleted later",
    ] {
      let row = historyRow(prefix)
      reveal(row)
      XCTAssertTrue(row.exists, "rebuilt from Activity: \(prefix)")
    }
    let fed = historyRow("Feed the cat, Marked complete")
    reveal(fed)
    XCTAssertTrue(fed.exists)
    XCTAssertFalse(app.buttons["Reopen Feed the cat"].exists, "past facts are read-only")
    let report = historyRow("Send the weekly report, Scheduled")
    reveal(report)
    XCTAssertTrue(report.exists, "observed incomplete due reminder remains visible")
    XCTAssertFalse(app.buttons["Complete Send the weekly report"].exists)
    let undone = historyRow("Undone in Activity, Marked complete · No longer complete")
    reveal(undone)
    XCTAssertTrue(undone.exists, "Undo retains the fact and makes its result explicit")
    XCTAssertFalse(app.buttons["focus.settled"].exists, "no Settled section")
    app.swipeDown()
    app.swipeDown()
    shoot("past-day-light")

    // Back on today, the open one counts as overdue.
    app.returnToToday()
    let overdue = app.buttons["today.overdueShortcut"]
    reveal(overdue)
    overdue.tap()
    XCTAssertTrue(app.staticTexts["Send the weekly report"].waitForExistence(timeout: 3))
  }

  func testDeletedSourceFactOpensReadOnlyDetails() {
    launch()
    openYesterday()
    let row = historyRow("Old alarm, Alarm stopped")
    reveal(row)
    XCTAssertTrue(row.exists)
    row.tap()
    XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Old alarm"].exists)
    XCTAssertFalse(app.buttons["Complete Old alarm"].exists)
    app.buttons["Done"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: 5))
  }

  func testYesterdayInDarkMode() {
    launch(appearance: "dark")
    openYesterday()
    let row = historyRow("Return library books, Marked complete")
    reveal(row)
    XCTAssertTrue(row.exists)
    app.swipeDown()
    app.swipeDown()
    shoot("past-day-dark")
  }
}

import XCTest

/// Deleting an Apple Calendar event from Today removes exactly what was asked, on the day that was tapped: a repeating
/// event's "Delete This Event Only" removes that day's occurrence (another day's was removed once, on a real iCloud
/// calendar), "Delete All Future Events" keeps the past, and Delete Event in Apple's editor closes the editor (iOS 27
/// deletes without telling its delegate). Uses the simulator's own calendar, never a real one: the events are made by the
/// app's debug hooks (-debugCreateRepeatingEvent / -debugCreateSystemEvent) as if in the Calendar app, and removed after.
@MainActor
final class CalendarRecurringDeleteTests: XCTestCase {
  private var title = ""
  private let cal = Calendar.current
  private var yesterday: Date { cal.date(byAdding: .day, value: -1, to: .now)! }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: .now)! }

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      // The events start at the top of the current hour, so they are today's at any time of day.
      title = "Repeat check \(Int(Date.now.timeIntervalSince1970) % 100000)"
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      // Remove what the test made (the whole series, past occurrences included).
      // A slow simulator can fail the relaunch ("Failed to terminate"); that is not the test's result.
      XCTExpectFailure("cleanup only", options: .nonStrict()) {
        let app = launch(["-debugDeleteSystemEvent", title])
        _ = app.weekStripDay(.now).waitForExistence(timeout: 10)
        sleep(2)
        app.terminate()
      }
      super.tearDown()
    }
  }

  private func launch(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingCalendarSync"] + extra
    app.launch()
    return app
  }

  /// Sync on, then a launch that makes the event in the system calendar, then Today with its row on screen.
  private func start(repeating: Bool) -> XCUIApplication {
    var app = launch()
    enableCalendarSync(app)
    app.terminate()
    app = launch([repeating ? "-debugCreateRepeatingEvent" : "-debugCreateSystemEvent", title])
    app.buttons["Today"].firstMatch.tap()
    XCTAssertTrue(isListedToday(app), "the new event is listed on Today")
    return app
  }

  private func row(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title))
      .firstMatch
  }

  /// Whether today's occurrence is gone from Today.
  private func isTodaysRowGone(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
    row(app).waitForNonExistence(timeout: timeout)
  }

  /// The Today list is lazy and opens on the now line, and other tests leave events at the same hour: look further
  /// down, then further up, for the row.
  private func isListedToday(_ app: XCUIApplication) -> Bool {
    var found = row(app).waitForExistence(timeout: 5)
    for _ in 0..<6 where !found {
      app.swipeUp()
      found = row(app).waitForExistence(timeout: 1)
    }
    for _ in 0..<12 where !found {
      app.swipeDown()
      found = row(app).waitForExistence(timeout: 1)
    }
    return found
  }

  /// Whether the Calendar tab's Month list shows the event on `day`. Ends on the Calendar tab.
  private func isListed(on day: Date, _ app: XCUIApplication) -> Bool {
    app.buttons["Calendar"].firstMatch.tap()
    let month = app.buttons["calendar.mode.month"]
    XCTAssertTrue(month.waitForExistence(timeout: 5))
    month.tap()
    let pager = app.descendants(matching: .any)["calendar.monthPager"]
    XCTAssertTrue(pager.waitForExistence(timeout: 5))
    // Yesterday or tomorrow can be in the next or previous month.
    if !cal.isDate(day, equalTo: .now, toGranularity: .month) {
      if day > .now { pager.swipeUp() } else { pager.swipeDown() }
    }
    let cell = app.descendants(matching: .any)[calendarDayID(day)]
    XCTAssertTrue(cell.waitForExistence(timeout: 5), "the day is in the grid")
    cell.tap()
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH %@", title))
      .firstMatch
    var found = row.waitForExistence(timeout: 4)
    let list = app.descendants(matching: .any)["calendar.dayList"]
    for _ in 0..<4 where !found && list.exists {
      list.swipeUp()
      found = row.waitForExistence(timeout: 1)
    }
    return found
  }

  func testAskAIMovesOnlyTheSelectedRepeatingOccurrence() {
    let app = start(repeating: true)
    row(app).press(forDuration: 1.2)
    let ask = app.buttons["Ask AI"].firstMatch
    XCTAssertTrue(ask.waitForExistence(timeout: 5))
    ask.tap()
    let input = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Move it to tomorrow at 11am")
    app.buttons["ask-send"].tap()
    // No attendees: the move of this occurrence is applied right after the reply, with Undo.
    XCTAssertTrue(app.staticTexts["The calendar event was moved."].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["ask-undo"].waitForExistence(timeout: 5))
    app.buttons["chat.close"].tap()
    XCTAssertTrue(isListed(on: yesterday, app), "the earlier series occurrence is unchanged")
  }

  private func deleteFromRow(_ app: XCUIApplication) {
    row(app).press(forDuration: 1.2)
    let delete = app.buttons["Delete"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "the long-press menu has Delete")
    delete.tap()
  }

  /// Opens the row in Apple's editor and taps its Delete Event.
  private func deleteInAppleEditor(_ app: XCUIApplication) -> XCUIElement {
    row(app).tap()
    let editor = app.staticTexts["Edit Event"]
    // Today scrolls to the now line just after it appears; a tap during that scroll can be lost on a slow simulator.
    if !editor.waitForExistence(timeout: 10) { row(app).tap() }
    XCTAssertTrue(editor.waitForExistence(timeout: 10), "the existing-event editor opens")
    XCTAssertTrue(
      app.buttons["alert-cell"].waitForExistence(timeout: 20), "the full system editor is ready")
    let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Delete Event'"))
      .firstMatch
    if !delete.waitForExistence(timeout: 2) { app.swipeUp() }  // at the bottom of the editor
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "the editor has Delete Event")
    delete.tap()
    return editor
  }

  /// Apple's confirmation sheet button (an action sheet in the editor).
  private func confirm(_ label: String, _ app: XCUIApplication) {
    let button = app.buttons[label].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), "\(label) is offered")
    button.tap()
  }

  // MARK: Repeating

  func testDeleteThisEventOnlyFromRowKeepsOtherDays() {
    let app = start(repeating: true)
    deleteFromRow(app)
    confirm("Delete This Event Only", app)
    XCTAssertTrue(isTodaysRowGone(app), "today's occurrence is gone")
    // A series offers no Undo: a plain copy put back would not repeat.
    XCTAssertFalse(
      app.buttons["Undo"].waitForExistence(timeout: 2), "no Undo for one occurrence of a series")
    XCTAssertTrue(isListed(on: tomorrow, app), "tomorrow's occurrence is still there")
    XCTAssertTrue(isListed(on: yesterday, app), "and yesterday's")
    XCTAssertFalse(isListed(on: .now, app), "today's is gone in the Calendar tab too")
  }

  func testDeleteAllFutureEventsFromTodayKeepsThePast() {
    let app = start(repeating: true)
    deleteFromRow(app)
    confirm("Delete All Future Events", app)
    XCTAssertTrue(row(app).waitForNonExistence(timeout: 5), "today's occurrence is gone")
    XCTAssertFalse(isListed(on: tomorrow, app), "tomorrow's is gone too")
    XCTAssertTrue(isListed(on: yesterday, app), "yesterday's stays")
  }

  func testDeleteThisEventOnlyInAppleEditorClosesItAndKeepsOtherDays() {
    let app = start(repeating: true)
    let editor = deleteInAppleEditor(app)
    confirm("Delete This Event Only", app)
    XCTAssertTrue(editor.waitForNonExistence(timeout: 8), "the editor closes after Delete Event")
    XCTAssertTrue(isTodaysRowGone(app), "today's occurrence is gone")
    XCTAssertTrue(isListed(on: tomorrow, app), "tomorrow's occurrence is still there")
  }

  // MARK: One-off

  func testOneOffEventDeletedFromRowWithUndo() {
    let app = start(repeating: false)
    deleteFromRow(app)
    XCTAssertFalse(
      app.buttons["Delete This Event Only"].waitForExistence(timeout: 1),
      "a one-off event isn't asked about")
    XCTAssertTrue(row(app).waitForNonExistence(timeout: 5), "the event is gone")
    let undo = app.buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 3), "a one-off delete can be undone")
    undo.tap()
    XCTAssertTrue(isListedToday(app), "Undo puts it back")
  }

  func testOneOffEventDeletedInAppleEditorClosesIt() {
    let app = start(repeating: false)
    let editor = deleteInAppleEditor(app)
    confirm("Delete Event", app)
    XCTAssertTrue(editor.waitForNonExistence(timeout: 8), "the editor closes after Delete Event")
    XCTAssertTrue(row(app).waitForNonExistence(timeout: 5), "the event is gone")
  }

  /// Deleted in Apple Calendar (the hook removes it as the Calendar app would) → not on Today after the next launch.
  /// The case of an event Today created is `CalendarDeleteSyncTests.testEventDeletedInAppleCalendarDisappearsHere`.
  func testEventDeletedInAppleCalendarIsGoneFromToday() {
    var app = start(repeating: true)
    app.terminate()
    app = launch(["-debugDeleteSystemEvent", title])
    app.buttons["Today"].firstMatch.tap()
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 10), "Today loaded")
    sleep(2)
    XCTAssertFalse(isListedToday(app), "gone from Today")
  }
}

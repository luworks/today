import XCTest

/// Save is a completion action even when an existing event has no edits.
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

  private func openRow(_ app: XCUIApplication, _ title: String) {
    let event = row(app, title)
    XCTAssertTrue(event.waitForExistence(timeout: 10))
    let list = app.descendants(matching: .any)["calendar.dayList"].firstMatch
    // AX can report a row as hittable while its center is behind Ask AI.
    // Use the actual list/row frames to reveal it before tapping.
    let visible = list.frame.intersection(
      CGRect(
        x: 0, y: 0, width: app.frame.width,
        height: app.frame.height - 110))
    for _ in 0..<6 {
      if visible.contains(CGPoint(x: event.frame.midX, y: event.frame.midY)) { break }
      let upwards = event.frame.midY > visible.maxY
      let x = visible.midX / app.frame.width
      let low = (visible.maxY - 25) / app.frame.height
      let high = (visible.minY + 25) / app.frame.height
      app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: upwards ? low : high))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(
            withNormalizedOffset: CGVector(dx: x, dy: upwards ? high : low)))
    }
    guard visible.contains(CGPoint(x: event.frame.midX, y: event.frame.midY)), event.isHittable
    else {
      XCTFail(
        "Event row is outside the unobscured list: \(event.frame), visible \(visible). \(app.debugDescription)"
      )
      return
    }
    event.tap()
  }

  func testExistingNativeEventUnchangedSaveCloses() {
    nativeSave(changed: false)
  }

  func testExistingNativeEventChangedSaveClosesAndPersists() {
    nativeSave(changed: true)
  }

  func testExistingNativeEventSaveFailureKeepsEditor() {
    nativeSave(changed: true, failing: true)
  }

  func testExistingAllDayNativeEventUnchangedSaveCloses() {
    nativeSave(changed: false, allDay: true)
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

  private func nativeSave(changed: Bool, failing: Bool = false, allDay: Bool = false) {
    let title = "Save check \(UUID().uuidString.prefix(8))"
    let app = XCUIApplication()
    let base =
      TestData.fixtureArguments("event-save.json") + [
        "-uiTestingCalendarSync", "-uiTestingCalendarSaveMetadata", "-appearance", "dark",
      ]
      + (failing ? ["-uiTestingEventSaveFailure"] : [])
      + (allDay ? ["-uiTestingCalendarSaveAllDay"] : [])
    app.launchArguments = base
    app.launch()
    enableCalendarSync(app)
    app.terminate()
    addTeardownBlock {
      app.terminate()
      app.launchArguments = base + ["-debugDeleteSystemEvent", title, "-uiTestingCleanupEventSave"]
      app.launch()
      XCTAssertTrue(app.buttons["Calendar"].firstMatch.waitForExistence(timeout: 5))
    }
    app.launchArguments = base + ["-debugCreateSystemEvent", title]
    app.launch()
    calendar(app)
    openRow(app, title)
    let editor = app.staticTexts["Edit Event"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    if allDay {
      let dates = app.descendants(matching: .any)["event.allDayDates"].firstMatch
      XCTAssertEqual(
        dates.value as? String,
        Date.now.formatted(date: .abbreviated, time: .omitted) + " · All day",
        "a single all-day event shows only its actual calendar day")
    }
    let savedTitle = changed ? title + " updated" : title
    if changed {
      let field = app.textFields["title-field"]
      XCTAssertTrue(field.waitForExistence(timeout: 3))
      field.tap()
      field.typeText(" updated")
    }
    app.buttons["Done"].tap()
    if failing {
      let error = app.staticTexts["event.save.error"]
      XCTAssertTrue(error.waitForExistence(timeout: 3))
      XCTAssertTrue(error.label.contains("Calendar is temporarily unavailable"))
      XCTAssertTrue(editor.exists, "a failed save keeps the editor and draft open")
      XCTAssertEqual(app.textFields["title-field"].value as? String, savedTitle)
      app.buttons["Cancel"].tap()
      return
    }
    XCTAssertTrue(
      editor.waitForNonExistence(timeout: 5), "successful checkmark save returns to Calendar")
    XCTAssertTrue(app.buttons["calendar.mode.month"].isHittable)
    app.terminate()
    app.launchArguments = base
    app.launch()
    calendar(app)
    XCTAssertTrue(
      row(app, savedTitle).waitForExistence(timeout: 10), "saved event survives a fresh local store"
    )
    openRow(app, savedTitle)
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["https://example.com/calendar-save"].exists, "unedited URL survives saving")
    XCTAssertEqual(
      app.descendants(matching: .any)["event.alerts"].firstMatch.value as? String, "2 alerts",
      "all original alerts survive saving")
    XCTAssertTrue(
      app.textViews.matching(NSPredicate(format: "value == %@", "Preserve event notes")).firstMatch
        .exists
        || app.textFields.matching(NSPredicate(format: "value == %@", "Preserve event notes"))
          .firstMatch.exists,
      "unedited notes survive saving")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Cancel"].tap()
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

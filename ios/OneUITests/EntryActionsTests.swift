import XCTest

/// Calendar entries behave like tasks: long-press for a menu, swipe from the right to delete; and a task completed on
/// Today leaves the day. Runs on the in-memory sample data (the system calendar is never touched).
@MainActor
final class EntryActionsTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      app.launch()
    }
  }

  private func row(_ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH %@", title)
    ).firstMatch
  }

  private func showMonth() {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.month"].tap()
  }

  /// Complete the circle of a planned task on Today and it disappears from the day.
  func testCompletedTaskLeavesToday() {
    let title = app.staticTexts["Write up design review notes"]
    XCTAssertTrue(title.waitForExistence(timeout: 8), "a planned task is on Today")
    app.buttons["Complete Write up design review notes"].tap()
    XCTAssertTrue(title.waitForNonExistence(timeout: 5), "completing it removes it from the day")
    XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3), "with an Undo")
  }

  /// Today's reminder menu keeps the usual date commands next to Settle, so a reminder is postponed in place.
  func testTodayReminderMenuMovesItToTomorrow() {
    let title = app.staticTexts["Write up design review notes"]
    XCTAssertTrue(title.waitForExistence(timeout: 8), "a planned task is on Today")
    title.press(forDuration: 1.0)
    for name in ["Show Details", "Flag", "Tomorrow", "Unschedule", "Settle", "Delete"] {
      XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), "the menu has \(name)")
    }
    app.buttons["Tomorrow"].tap()
    XCTAssertTrue(title.waitForNonExistence(timeout: 5), "it leaves today for tomorrow")
  }

  func testAskAIOnReminderResolvesMoveItToThatReminder() {
    let title = app.staticTexts["Write up design review notes"]
    XCTAssertTrue(title.waitForExistence(timeout: 8))
    title.press(forDuration: 1.0)
    let askAI = app.buttons["Ask AI"]
    XCTAssertTrue(askAI.waitForExistence(timeout: 3))
    askAI.tap()

    let field = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("Move it to tomorrow at 5pm")
    let send = app.buttons["ask-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.tap()

    let card = app.descendants(matching: .any).matching(identifier: "change-card").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 90), "The selected reminder gets a move preview")
    XCTAssertTrue(card.staticTexts["Write up design review notes"].exists)
    XCTAssertTrue(card.staticTexts["Change item"].exists)
    XCTAssertTrue(card.buttons["Apply"].exists, "The move still requires confirmation")
    XCTAssertFalse(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Which item do you mean"))
        .firstMatch.exists,
      "The item selected before opening AI resolves the pronoun")
  }

  func testLongPressOnAnEventOffersTheUsualActions() {
    showMonth()
    let dentist = row("Dentist")
    XCTAssertTrue(dentist.waitForExistence(timeout: 8))
    dentist.press(forDuration: 1.0)
    for name in ["Show Details", "Edit", "Delete"] {
      XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), "the menu has \(name)")
    }
  }

  func testSwipeLeftDeletesAnEvent() {
    showMonth()
    let dentist = row("Dentist")
    XCTAssertTrue(dentist.waitForExistence(timeout: 8))
    dentist.swipeLeft()
    let delete = app.buttons["Delete"]
    // A full swipe deletes at once; a shorter one leaves the Delete button open.
    if delete.waitForExistence(timeout: 1) { delete.tap() }
    XCTAssertTrue(dentist.waitForNonExistence(timeout: 5), "swipe from the right deletes the event")
  }

  func testSwipingARepeatingEventAsksFirst() {
    showMonth()
    let standup = row("Standup")
    XCTAssertTrue(standup.waitForExistence(timeout: 8))
    standup.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(
      delete.waitForExistence(timeout: 3), "a series never full-swipes away: Delete shows")
    delete.tap()
    XCTAssertTrue(
      app.buttons["Delete All Occurrences"].waitForExistence(timeout: 3), "and asks what to delete")
  }

  /// Deleting leaves an Undo in the system's undo stack too: shaking the phone offers "Undo Delete", like any iPhone app.
  func testShakeOffersUndoAfterDelete() throws {
    let shake = NSSelectorFromString("shake")
    try XCTSkipUnless(XCUIDevice.shared.responds(to: shake), "this Xcode cannot synthesize a shake")
    showMonth()
    let dentist = row("Dentist")
    XCTAssertTrue(dentist.waitForExistence(timeout: 8))
    dentist.swipeLeft()
    let delete = app.buttons["Delete"]
    if delete.waitForExistence(timeout: 1) { delete.tap() }
    XCTAssertTrue(dentist.waitForNonExistence(timeout: 5))
    _ = XCUIDevice.shared.perform(shake)
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5), "shaking offers the system's Undo prompt")
    XCTAssertTrue(alert.label.contains("Delete"), "it names the action: \(alert.label)")
    alert.buttons["Undo"].tap()
    XCTAssertTrue(dentist.waitForExistence(timeout: 5), "and undoing puts the event back")
  }
}

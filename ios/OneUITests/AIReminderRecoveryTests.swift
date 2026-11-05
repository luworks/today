import XCTest

/// Submitted one-off requests through FastLane, not signed in to Luna AI.
@MainActor
final class AIReminderRecoveryTests: XCTestCase {
  private var app: XCUIApplication!
  private let title = "去 costco 加油 买 粒粒"

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testSubmittedClockErrandPersistsDeadlineAndUndo() {
    launch(nativeReminders: true)
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let sync = app.switches["Apple Reminders"]
    XCTAssertTrue(sync.waitForExistence(timeout: 5))
    if sync.value as? String != "1" {
      sync.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      for label in ["Allow Full Access", "Allow"]
      where springboard.buttons[label].waitForExistence(timeout: 3) {
        springboard.buttons[label].tap()
        break
      }
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "value == '1'"), evaluatedWith: sync)
        ], timeout: 8), .completed)
    app.terminate()
    launch(nativeReminders: true)
    open("New chat")
    send("11点去 costco 加油 买 粒粒")
    assertAdded()
    let backend = app.staticTexts["syncDump.apple"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS '11:00'", title),
            evaluatedWith: backend)
        ], timeout: 10), .completed, "Fresh EventKit readback must retain the original deadline")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Submitted 09-11 errand saved at 11-00 with Undo and Open"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["capture-open"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(app.descendants(matching: .any)["task.title"].firstMatch.value as? String, title)
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    XCTAssertEqual(app.switches["Deadline"].value as? String, "1")
    let clock = app.datePickers.firstMatch.buttons.matching(
      NSPredicate(format: "label CONTAINS '11:00'")
    ).firstMatch
    XCTAssertTrue(clock.exists, app.debugDescription)
    app.buttons["Cancel"].tap()
    app.buttons["capture-undo"].firstMatch.tap()
    XCTAssertTrue(app.buttons["capture-undo"].firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", title), evaluatedWith: backend)
        ], timeout: 10), .completed)
  }

  func testLegacyMixedLanguageFollowupsKeepTimeAndDoNotDuplicate() {
    launch()
    open("Costco wrong chat")
    send("setting reminder")
    assertAdded()
    // After Added, "one off" is not a continuation (#270): it never adds a second reminder.
    // Not signed in, it gets the sign-in reply and the draft goes back.
    sendKeepingDraft("one off")
    assertAdded()
    XCTAssertEqual(app.buttons.matching(identifier: "capture-open").count, 1)
    app.buttons["Close"].firstMatch.tap()
    open("Costco wrong chat")
    XCTAssertEqual(app.buttons.matching(identifier: "capture-open").count, 1)
    app.buttons["capture-open"].firstMatch.tap()
    XCTAssertEqual(app.descendants(matching: .any)["task.title"].firstMatch.value as? String, title)
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    XCTAssertEqual(app.switches["Deadline"].value as? String, "1")
    XCTAssertTrue(
      app.datePickers.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS '11:00'"))
        .firstMatch.exists)
    app.buttons["Cancel"].tap()
    app.buttons["capture-undo"].firstMatch.tap()
    sendKeepingDraft("one off")
    XCTAssertFalse(
      app.buttons["capture-open"].exists, "A continuation cannot recreate an undone reminder")
  }

  func testOrdinaryChatStaysChatAndFailedCreationCanRetry() {
    launch(failOnce: true)
    open("New chat")
    // Not signed in, a question gets no preview: the AI is unavailable and the draft goes back.
    let field = app.textViews["Ask AI or add anything"].firstMatch
    field.tap()
    field.typeText("What happens if I set a reminder?")
    app.buttons["ask-send"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sign in to Luna AI'"))
        .firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["capture-open"].exists)
    XCTAssertFalse(app.buttons["capture-title"].exists)
    // Close drops the returned draft; the reminder is asked for in a new chat.
    app.buttons["Close"].firstMatch.tap()
    open("New chat")
    send("11点去 costco 加油 买 粒粒")
    XCTAssertTrue(app.buttons["Add"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["capture-open"].exists, "A failed save is never Added")
    // The closed first chat stays built (hidden); tap this chat's own Add.
    let add = app.buttons.matching(identifier: "Add").allElementsBoundByIndex.first(
      where: \.isHittable)
    XCTAssertNotNil(add)
    add?.tap()
    assertAdded()
    XCTAssertEqual(app.buttons.matching(identifier: "capture-open").count, 1)
    app.buttons["capture-undo"].firstMatch.tap()
    XCTAssertTrue(app.buttons["capture-undo"].firstMatch.waitForNonExistence(timeout: 5))
  }

  private func launch(nativeReminders: Bool = false, failOnce: Bool = false) {
    app.launchArguments =
      TestData.fixtureArguments("ai-oneoff-reminder-ui.json") + ["-uiTestingNow", "09:11"]
    if nativeReminders {
      app.launchArguments += ["-uiTestingRemindersSync", "-uiTestingSyncDump", title]
    }
    if failOnce { app.launchArguments += ["-uiTestingFailReminderCreationOnce"] }
    app.launch()
  }
  private func open(_ name: String) {
    let button = app.buttons[name].firstMatch
    if !button.isHittable || !button.isFullyVisible(in: app.frame) {
      let menu = app.buttons["Open menu"].firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      menu.tap()
    }
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    XCTAssertTrue(button.isHittable && button.isFullyVisible(in: app.frame))
    button.tap()
    XCTAssertTrue(app.textViews["Ask AI or add anything"].firstMatch.waitForExistence(timeout: 5))
  }
  private func send(_ text: String) {
    let field = app.textViews["Ask AI or add anything"].firstMatch
    field.tap()
    field.typeText(text)
    app.buttons["ask-send"].tap()
    XCTAssertTrue(app.buttons["ask-send"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Thinking…"].waitForNonExistence(timeout: 15))
  }
  /// A message the rules don't take while not signed in: the reply asks to sign in, the draft returns.
  private func sendKeepingDraft(_ text: String) {
    let field = app.textViews["Ask AI or add anything"].firstMatch
    field.tap()
    field.typeText(text)
    app.buttons["ask-send"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sign in to Luna AI'"))
        .firstMatch.waitForExistence(timeout: 5))
    let draft = app.textViews["Ask AI or add anything"].firstMatch
    draft.tap()
    draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
  }
  private func assertAdded() {
    XCTAssertTrue(app.buttons["capture-open"].firstMatch.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["capture-undo"].firstMatch.exists)
    XCTAssertEqual(app.buttons["capture-title"].firstMatch.label, title)
  }
}

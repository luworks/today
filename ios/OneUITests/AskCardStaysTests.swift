import XCTest

/// The capture card stays in the conversation: Added (Undo, Open), Undone (Add again) and Dropped, and the final state
/// is there when the chat is reopened from the sidebar. Runs on the test dataset, not signed in to Luna AI, so FastLane
/// reads the sentence; a clear request is added right after the reply (owner decision 2026-11-02), and only an alarm
/// without a time waits on an open card.
@MainActor
final class AskCardStaysTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.launchArguments
      app.launch()
      app.buttons["Ask AI or add anything"].tap()
    }
  }

  private var field: XCUIElement {
    let f = app.textViews["Ask AI or add anything"].firstMatch
    return f.exists ? f : app.textViews.firstMatch
  }

  private func send(_ text: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(text + "\n")
  }

  private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

  private func shot(_ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
    if let dir = ProcessInfo.processInfo.environment["TEST_RUNNER_CARD_SHOTS"] {
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? app.screenshot().pngRepresentation.write(
        to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
    }
  }

  /// Closes the chat, opens the sidebar and taps the newest conversation.
  private func reopenFromSidebar(containing word: String) {
    app.buttons["Close"].tap()
    let menu = app.buttons["Open menu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    let row = app.buttons.matching(
      NSPredicate(format: "identifier == 'conversation.row' AND label CONTAINS %@", word)
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 6), "the conversation is in the sidebar")
    row.tap()
  }

  private func replaceTitle(with title: String) {
    let field =
      app.textFields["capture-title-field"].exists
      ? app.textFields["capture-title-field"] : app.textViews["capture-title-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    let old = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + title)
  }

  func testReportedChineseTitleAndTime() {
    send("今天晚上11点的时候提醒我，必须要睡觉")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 20))
    XCTAssertEqual(app.buttons["capture-title"].label, "必须要睡觉")
    let time = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS '23:00' OR label CONTAINS '11:00'")
    ).firstMatch
    XCTAssertTrue(time.exists, "11 at night stays 23:00 (localized display)")
    XCTAssertTrue(app.buttons["capture-undo"].exists, "Send authorizes this clear one-off reminder")
    shot("capture-reported-title-time")
  }

  /// The title of an added reminder is editable on its card: Cancel keeps it, Save renames the saved reminder.
  func testPendingTitleSaveAndCancelStillRequireAdd() {
    send("Remind me to review the draft tomorrow at 3pm every week")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["capture-title"].waitForExistence(timeout: 5))
    let original = app.buttons["capture-title"].label
    app.buttons["capture-title"].tap()
    replaceTitle(with: "Cancelled draft")
    app.buttons["capture-title-cancel"].tap()
    XCTAssertEqual(app.buttons["capture-title"].label, original)
    app.buttons["capture-title"].tap()
    replaceTitle(with: "Review the final draft")
    app.buttons["capture-title-save"].tap()
    XCTAssertEqual(app.buttons["capture-title"].label, "Review the final draft")
    XCTAssertFalse(app.buttons["Add"].exists, "nothing waits for Add")
    XCTAssertTrue(any("capture-added").exists)
    app.buttons["capture-open"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.textFields["task.title"].value as? String, "Review the final draft",
      "the real saved reminder changed")
  }

  func testAddedAlarmTitleSaveCancelReopenAndUndo() {
    // The Alarm kind above the composer makes this an alarm; the clear request is added at once.
    let alarm = app.buttons["ask-kind-alarm"]
    XCTAssertTrue(alarm.waitForExistence(timeout: 10))
    alarm.tap()
    send("今天晚上11点的时候提醒我，必须要睡觉，每天")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["New alarm"].exists, "added as an alarm")
    let original = app.buttons["capture-title"].label
    app.buttons["capture-title"].tap()
    replaceTitle(with: "Cancelled alarm")
    app.buttons["capture-title-cancel"].tap()
    XCTAssertEqual(app.buttons["capture-title"].label, original)
    app.buttons["capture-title"].tap()
    replaceTitle(with: "该睡觉了")
    app.buttons["capture-title-save"].tap()
    XCTAssertEqual(app.buttons["capture-title"].label, "该睡觉了")
    app.buttons["capture-open"].tap()
    XCTAssertEqual(
      app.textFields["alarm.label"].value as? String, "该睡觉了", "the real saved alarm changed")
    app.buttons["Cancel"].tap()
    reopenFromSidebar(containing: "睡觉")
    XCTAssertEqual(
      app.buttons["capture-title"].label, "该睡觉了", "StoredCard persists the saved title")
    app.buttons["capture-open"].tap()
    XCTAssertEqual(app.textFields["alarm.label"].value as? String, "该睡觉了")
    app.buttons["Cancel"].tap()
    app.buttons["capture-undo"].tap()
    XCTAssertTrue(
      any("capture-undone").waitForExistence(timeout: 5),
      "creation Undo still removes the renamed alarm")
    XCTAssertFalse(
      app.buttons["capture-title"].exists, "an undone card cannot rename a deleted alarm")
    shot("capture-renamed-alarm-undone")
  }

  func testAddedCardStaysThenUndoAndAddAgain() {
    send("Order printer paper tomorrow at 3pm")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 20))
    let title = app.buttons["capture-title"]
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "Order printer paper")

    // The card is still there, now confirmed; there is no separate "Added …" text line.
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 5), "the card shows Added")
    XCTAssertEqual(
      app.buttons["capture-title"].label, "Order printer paper",
      "same card: the title is still there")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'alerts you'")).firstMatch
        .exists, "and the time line")
    XCTAssertFalse(
      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Added “'")).firstMatch
        .exists,
      "the old text confirmation is gone")
    XCTAssertFalse(
      app.buttons["Add"].exists || app.buttons["Cancel"].exists, "Add and Cancel are replaced")
    XCTAssertFalse(
      app.buttons["capture.kind.task"].exists, "and so is the Reminder / Event / Alarm switcher")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH 'Added: Order printer paper'")
      ).firstMatch.exists,
      "the card's accessibility label carries the confirmation")
    shot("card-added")

    // Open shows the created reminder.
    app.buttons["capture-open"].tap()
    XCTAssertTrue(
      app.textFields["task.title"].waitForExistence(timeout: 5), "Open shows the reminder")
    XCTAssertEqual(app.textFields["task.title"].value as? String, "Order printer paper")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))

    // Undo takes back exactly that; the card says Undone and offers Add again.
    app.buttons["capture-undo"].tap()
    XCTAssertTrue(any("capture-undone").waitForExistence(timeout: 5))
    XCTAssertFalse(any("capture-added").exists)
    XCTAssertTrue(app.buttons["capture-add-again"].exists)
    XCTAssertTrue(app.staticTexts["Order printer paper"].exists, "the card stays")

    app.buttons["capture-add-again"].tap()
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 5), "Add again writes it again")
    app.buttons["capture-undo"].tap()
    XCTAssertTrue(any("capture-undone").waitForExistence(timeout: 5))

    // Reopened from the sidebar, the card is there in its final state.
    reopenFromSidebar(containing: "printer")
    XCTAssertTrue(any("capture-undone").waitForExistence(timeout: 5), "the saved chat shows Undone")
    XCTAssertTrue(app.staticTexts["Order printer paper"].exists)
    XCTAssertFalse(any("capture-stack").buttons["Add"].exists, "a decided card is not an open card")

    // And the reminder is not anywhere: Search does not find it.
    app.buttons["Close"].tap()
    app.buttons["Search"].tap()
    let search = app.textFields["search.field"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.typeText("printer")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch
        .waitForExistence(timeout: 5),
      "Undo removed the reminder")
  }

  func testAddedStateSurvivesReopening() {
    send("Order printer paper tomorrow at 3pm")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 20))
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 5))
    reopenFromSidebar(containing: "printer")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 5), "the saved chat shows Added")
    XCTAssertTrue(app.buttons["capture-undo"].exists)
    // Undo still works from the reopened chat.
    app.buttons["capture-undo"].tap()
    XCTAssertTrue(any("capture-undone").waitForExistence(timeout: 5))
  }

  /// Only an alarm without a time is left open; Cancel on it leaves a dimmed Dropped card.
  func testCancelLeavesADimmedDroppedCard() {
    send("make a alarm")
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 90))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(any("capture-dropped").waitForExistence(timeout: 5), "the card stays, Dropped")
    XCTAssertTrue(any("capture-stack").staticTexts["Alarm"].exists)
    XCTAssertFalse(
      app.buttons["Add"].exists || app.buttons["Cancel"].exists
        || app.buttons["capture-undo"].exists, "no actions")
    shot("card-dropped")

    reopenFromSidebar(containing: "alarm")
    XCTAssertTrue(
      any("capture-dropped").waitForExistence(timeout: 5), "the saved chat shows Dropped")
    XCTAssertTrue(any("capture-stack").staticTexts["Alarm"].exists)
  }

  /// An open card (an alarm still waiting for its time) is dropped when the next line asks for something else.
  func testNewLineAfterAnOpenCardDropsIt() {
    send("make a alarm")
    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 90))
    send("Water the office plants friday at 9am every week")
    XCTAssertTrue(
      any("capture-dropped").waitForExistence(timeout: 90), "the earlier card is Dropped")
    XCTAssertTrue(any("capture-added").waitForExistence(timeout: 10), "the new line is added")
    XCTAssertFalse(app.buttons["Add"].exists, "no open card is left")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "capture-added").count, 1)
  }
}

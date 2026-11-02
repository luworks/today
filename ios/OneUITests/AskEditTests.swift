import XCTest

/// AI page flows on the sample data: a clear request is applied right after the reply, with Undo (owner decision
/// 2026-11-02). A capture sentence is added, a saved reminder's repeat follow-up is applied with an Undo row, and an
/// edit of an existing item by name goes to the agent (scripted, `-uiTestingAgentScript`) and comes back as an
/// applied agent change card with Undo.
/// Screenshots are attached to the result bundle.
@MainActor
final class AskEditTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
    }
  }

  private func launch(_ extra: [String] = []) {
    app.launchArguments = ["-uiTesting"] + extra
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
  }

  private func shot(_ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
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

  private func label(containing s: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
  }

  /// Text on the newest preview card (earlier cards stay in the chat as Added / Dropped).
  private func cardText(containing s: String) -> XCUIElement {
    let stacks = app.descendants(matching: .any).matching(identifier: "capture-stack")
    let stack = stacks.element(boundBy: max(stacks.count - 1, 0))
    let title = stack.buttons["capture-title"]
    if title.exists && title.label.contains(s) { return title }
    let text = stack.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    if !text.exists {
      let diagnostic = XCTAttachment(string: stack.debugDescription)
      diagnostic.name = "Newest capture hierarchy for missing text: \(s)"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
      shot("missing-capture-text")
    }
    return text
  }

  // MARK: Capture

  // Sentence routing is covered by AskRouterTests; retain the real direct-save receipt and Undo.
  func testDirectCaptureShowsReceiptAndUndo() {
    launch()
    send("Call Alex tomorrow at 3pm")
    let stack = app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(NSPredicate(format: "label CONTAINS %@", "Call Alex")).firstMatch
    XCTAssertTrue(stack.buttons["capture-open"].waitForExistence(timeout: 90))
    XCTAssertTrue(stack.descendants(matching: .any)["capture-added"].exists)
    XCTAssertTrue(cardText(containing: "Call Alex").exists)
    XCTAssertTrue(cardText(containing: "New reminder").exists)
    XCTAssertTrue(cardText(containing: "alerts you").exists)
    stack.buttons["capture-undo"].tap()
    XCTAssertTrue(stack.descendants(matching: .any)["capture-undone"].waitForExistence(timeout: 5))
  }

  // MARK: Edit

  /// The repeat follow-up on a saved reminder is applied at once (no attendees), with an Undo row.
  func testSavedReminderDailyFollowupRequiresApplyAndSupportsUndo() {
    launch()
    send("Remind me to buy milk tomorrow at 3pm")
    XCTAssertTrue(
      app.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 20))
    send("Actually make it every day.")
    let updated = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Updated “buy milk” to repeat every day."))
    XCTAssertTrue(updated.firstMatch.waitForExistence(timeout: 10), "applied without a tap")
    let undo = app.buttons["ask-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5), "with Undo")
    XCTAssertFalse(app.buttons["Apply"].exists, "nothing waits for Apply")
    shot("saved-reminder-daily-applied")
    undo.tap()
    XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
    send("Make that reminder repeat every day at 3pm.")
    expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: updated)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(undo.waitForExistence(timeout: 5), "the second request is applied too, with Undo")
    XCTAssertFalse(app.buttons["Apply"].exists)
    undo.tap()
    XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
  }

  func testEdit_moveEventApplyUndo() {
    // The agent's move is applied after the run; the scripted "Moving Dentist to 5pm." is replaced by a receipt.
    launch(["-uiTestingAgentScript", "move-dentist"])
    send("Move Dentist to 5pm")
    let card = app.descendants(matching: .any)["agent-change-card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 30), "agent change card for the Dentist move")
    XCTAssertTrue(label(containing: "Move event").exists)
    XCTAssertTrue(
      app.staticTexts["agent-change-times"].label.contains("Today 15:00 → Today 17:00"),
      "old → new time on the card")
    let undo = app.buttons["agent-change-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "Applied right after the reply, with Undo")
    XCTAssertFalse(app.buttons["agent-change-apply"].exists, "nothing waits for Apply")
    XCTAssertTrue(
      label(containing: "Changed the event “Dentist”. Tap Undo if you don't want it.")
        .waitForExistence(timeout: 10), "the reply is a receipt")
    shot("edit-1-applied")
    undo.tap()
    XCTAssertTrue(
      card.staticTexts["Undone"].waitForExistence(timeout: 10), "Undo puts Dentist back")
    shot("edit-1-undone")
  }
}

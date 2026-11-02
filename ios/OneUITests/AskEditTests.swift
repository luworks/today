import XCTest

/// AI page flows on the sample data: capture sentences become preview cards (or a clear one-off reminder is added),
/// a saved reminder's repeat follow-up becomes a ChangeCard, and an edit of an existing item by name goes to the agent
/// (scripted, `-uiTestingAgentScript`) and comes back as an agent change card with Apply / Undo.
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

  func testCapture_fiveSentences() {
    launch()
    let cases: [(input: String, expect: [String], notExpect: [String])] = [
      ("Call Alex tomorrow at 3pm", ["Call Alex", "New reminder", "alerts you"], []),
      ("周五晚上7点和朋友聚餐", ["和朋友聚餐", "19:00"], []),
      ("明早7点叫我起床", ["Alarm Tomorrow 07:00"], []),
      ("提醒我下周一交报销单", ["交报销单"], ["Alarm "]),
      ("30分钟后关烤箱", ["关烤箱", "New reminder", "alerts you"], []),
    ]
    for (i, c) in cases.enumerated() {
      send(c.input)
      let direct = [0, 3, 4].contains(i)
      let stack = app.descendants(matching: .any).matching(identifier: "capture-stack").element(
        boundBy: i)
      let action = direct ? stack.buttons["capture-open"] : stack.buttons["Add"]
      XCTAssertTrue(action.waitForExistence(timeout: 90), "card for \(c.input)")
      if direct {
        XCTAssertTrue(stack.descendants(matching: .any)["capture-added"].exists)
      }
      for e in c.expect {
        XCTAssertTrue(cardText(containing: e).exists, "'\(e)' on the card for \(c.input)")
      }
      for n in c.notExpect {
        XCTAssertFalse(cardText(containing: n).exists, "no '\(n)' for \(c.input)")
      }
      shot("capture-\(i + 1)")
      if direct {
        if i != 0 { stack.buttons["capture-undo"].tap() }
      } else {
        app.buttons["Cancel"].tap()
      }
    }
  }

  // MARK: Edit

  func testSavedReminderDailyFollowupRequiresApplyAndSupportsUndo() {
    launch()
    send("Remind me to buy milk tomorrow at 3pm")
    XCTAssertTrue(label(containing: "Added").waitForExistence(timeout: 20))
    send("Actually make it every day.")
    let card = app.descendants(matching: .any).matching(identifier: "change-card").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    XCTAssertTrue(card.staticTexts["buy milk"].exists)
    XCTAssertTrue(card.staticTexts["Repeat every day. Nothing changes until you tap Apply."].exists)
    XCTAssertTrue(app.buttons["Apply"].exists)
    shot("saved-reminder-daily-preview")
    app.buttons["Apply"].tap()
    XCTAssertTrue(
      label(containing: "Updated “buy milk” to repeat every day.").waitForExistence(timeout: 10))
    app.buttons["ask-undo"].tap()
    XCTAssertFalse(app.buttons["ask-undo"].exists)
    send("Make that reminder repeat every day at 3pm.")
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    XCTAssertTrue(card.staticTexts["buy milk"].exists)
    XCTAssertTrue(label(containing: "Tomorrow 15:00 → Tomorrow 15:00").exists)
    app.buttons["Cancel"].tap()
  }

  func testEdit_moveEventApplyUndo() {
    launch(["-uiTestingAgentScript", "move-dentist"])
    send("Move Dentist to 5pm")
    let card = app.descendants(matching: .any)["agent-change-card"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 30), "agent change card for the Dentist move")
    XCTAssertTrue(label(containing: "Move event").exists)
    XCTAssertTrue(
      app.staticTexts["agent-change-times"].label.contains("Today 15:00 → Today 17:00"),
      "old → new time on the card")
    XCTAssertTrue(
      label(containing: "Nothing changes until you apply it.").waitForExistence(timeout: 10))
    shot("edit-1-event-card")
    app.buttons["agent-change-apply"].tap()
    let undo = app.buttons["agent-change-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "Applied, with Undo")
    shot("edit-1-applied")
    undo.tap()
    XCTAssertTrue(
      card.staticTexts["Undone"].waitForExistence(timeout: 10), "Undo puts Dentist back")
    shot("edit-1-undone")
  }
}

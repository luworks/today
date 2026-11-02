import XCTest

/// Not signed in to Luna AI (TodayMock): FastLane requests and continuations only, no scripted model. An alarm with
/// its time is added right after the reply, with Undo and Open (owner decision 2026-11-02); one without waits.
@MainActor
final class AIAlarmContextTests: XCTestCase {
  private var app: XCUIApplication!
  private var loadedAt: Date!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.fixtureArguments("ai-alarm-context-ui.json")
      loadedAt = Date()
      app.launch()
      app.openSidebar()
    }
  }

  func testMixedRelativeAlarmPreviewAddAndUndo() {
    open("New chat")
    let sentAt = Date()
    send("提醒 烘干衣服 45min 后 alarm")
    assertAlarm(minutesFrom: sentAt, offset: 45)
    keepScreenshot("IMG6815 - alarm added with Undo and Open")
    // Send added the real alarm; Open shows it and Undo takes it back.
    XCTAssertTrue(app.buttons["capture-open"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["capture-open"].firstMatch.tap()
    XCTAssertTrue(app.textFields["alarm.label"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["alarm.label"].value as? String, "烘干衣服")
    app.buttons["Cancel"].firstMatch.tap()
    app.buttons["capture-undo"].firstMatch.tap()
    XCTAssertTrue(app.buttons["capture-undo"].firstMatch.waitForNonExistence(timeout: 5))
  }

  func testFullWrongHistoryRecoversOriginalClockAfterReopenAndNewChatIsIsolated() {
    open("Dryer full wrong chat")
    send("make a alarm")
    assertAlarm(minutesFrom: loadedAt, offset: 35)
    app.buttons["Close"].firstMatch.tap()
    app.buttons["Activity"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "activity.row").firstMatch
        .waitForExistence(timeout: 5), "Send wrote the alarm")
    app.buttons["Done"].firstMatch.tap()
    // Reopened, the chat still shows the alarm it added, at the original clock.
    open("Dryer full wrong chat")
    assertAlarm(minutesFrom: loadedAt, offset: 35)
    app.buttons["Close"].firstMatch.tap()
    open("New chat")
    send("make a alarm")
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 5))
    XCTAssertFalse(preview.buttons["Add"].isEnabled)
    XCTAssertEqual(preview.buttons["capture-title"].firstMatch.label, "Alarm")
    keepScreenshot("Stored wrong history recovery and isolated new chat")
  }

  /// The open card (an alarm still waiting for its time).
  private var preview: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "capture-stack").containing(
      .button, identifier: "Add"
    ).firstMatch
  }
  /// The visible thread's Added card (closed threads stay built, hidden).
  private var added: XCUIElement {
    let stacks = app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(.button, identifier: "capture-undo")
    return stacks.allElementsBoundByIndex.last(where: \.isHittable) ?? stacks.firstMatch
  }
  private func open(_ name: String) {
    let button = app.buttons[name].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    XCTAssertTrue(app.textViews["Ask AI or add anything"].waitForExistence(timeout: 5))
  }
  private func send(_ text: String) {
    let field = app.textViews["Ask AI or add anything"].firstMatch
    field.tap()
    field.typeText(text)
    app.buttons["ask-send"].tap()
    XCTAssertTrue(app.buttons["ask-send"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Thinking…"].waitForNonExistence(timeout: 15))
  }
  /// The alarm was added at once: an Added card with its title and clock, Undo and Open, and no Add.
  private func assertAlarm(minutesFrom anchor: Date, offset: Int) {
    let card = added
    XCTAssertTrue(card.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 10))
    XCTAssertTrue(card.staticTexts["New alarm"].exists)
    XCTAssertEqual(card.buttons["capture-title"].firstMatch.label, "烘干衣服")
    // Fixture loading and input may straddle a minute. The pure tests check exact timestamps.
    let candidates = (0...1).map {
      anchor.addingTimeInterval(Double((offset + $0) * 60)).formatted(
        date: .omitted, time: .shortened)
    }
    XCTAssertTrue(
      card.staticTexts.allElementsBoundByIndex.contains { label in
        candidates.contains { label.label.contains($0) }
      }, app.debugDescription)
    XCTAssertTrue(card.buttons["capture-undo"].exists)
    XCTAssertTrue(card.buttons["capture-open"].exists)
    XCTAssertEqual(
      app.buttons.matching(identifier: "Add").allElementsBoundByIndex.filter(\.isHittable).count, 0,
      "nothing waits for Add")
  }
  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

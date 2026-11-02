import XCTest

/// Not signed in to Luna AI (TodayMock): FastLane previews and continuations only, no scripted model.
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
    send("make a alarm")
    assertAlarm(minutesFrom: sentAt, offset: 45)
    keepScreenshot("IMG6815 two turns - complete alarm preview")
    // Only the real Add creates the alarm; Undo remains available afterwards.
    preview.buttons["Add"].tap()
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
      app.staticTexts["No activity yet"].waitForExistence(timeout: 5),
      "No planner writes before Add")
    app.buttons["Done"].firstMatch.tap()
    open("Dryer full wrong chat")
    send("make an alarm")
    assertAlarm(minutesFrom: loadedAt, offset: 35)
    app.buttons["Close"].firstMatch.tap()
    open("New chat")
    send("make a alarm")
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 5))
    XCTAssertFalse(preview.buttons["Add"].isEnabled)
    XCTAssertEqual(preview.buttons["capture-title"].firstMatch.label, "Alarm")
    keepScreenshot("Stored wrong history recovery and isolated new chat")
  }

  private var preview: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "capture-stack").containing(
      .button, identifier: "Add"
    ).firstMatch
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
  private func assertAlarm(minutesFrom anchor: Date, offset: Int) {
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 10))
    XCTAssertTrue(preview.buttons["Add"].isEnabled)
    XCTAssertTrue(preview.staticTexts["New alarm"].exists)
    XCTAssertEqual(preview.buttons["capture-title"].firstMatch.label, "烘干衣服")
    // Fixture loading and input may straddle a minute. The pure tests check exact timestamps.
    let candidates = (0...1).map {
      anchor.addingTimeInterval(Double((offset + $0) * 60)).formatted(
        date: .omitted, time: .shortened)
    }
    XCTAssertTrue(
      preview.staticTexts.allElementsBoundByIndex.contains { label in
        candidates.contains { label.label.contains($0) }
      }, app.debugDescription)
    XCTAssertFalse(app.buttons["capture-undo"].exists)
  }
  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

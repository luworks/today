import XCTest

@MainActor
final class AskConversationTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      app.launch()
      app.buttons["Ask AI or add anything"].tap()
    }
  }

  private func send(_ text: String) {
    let input = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText(text + "\n")
  }

  private func reply(_ text: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  func testReportedActivityMessageIsConversation() {
    send("我进行一个测试，然后看看我的 Activity 中是不是会选择显示")
    // Not signed in, conversation gets no rule preview: the AI is unavailable and the draft goes back.
    XCTAssertTrue(reply("需要登录 Luna AI").waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["ask-send"].exists, "the draft is back in the composer")
    XCTAssertFalse(app.buttons["Add"].exists)
    XCTAssertFalse(app.buttons["capture-add-all"].exists)
    XCTAssertFalse(reply("Added").exists, "nothing was added")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Activity conversation without capture"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Close"].firstMatch.tap()
    app.openSidebar()
    app.buttons["Activity"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 5))
  }

  /// The reminder is added right after the reply (owner decision 2026-11-02); a later question about an alarm
  /// neither turns it into an alarm nor adds anything else.
  func testExistingAlarmQuestionPreservesPendingReminder() {
    send("Call Alex tomorrow at 3pm every week")
    XCTAssertTrue(
      app.descendants(matching: .any)["capture-added"].firstMatch.waitForExistence(timeout: 20))
    XCTAssertTrue(
      reply("Added the reminder").waitForExistence(timeout: 5), "the reply is a receipt")
    XCTAssertTrue(reply("Call Alex").exists)
    XCTAssertTrue(reply("15:00").exists)
    // Asked last: not signed in, the question puts its draft back in the composer.
    send("Did I set an alarm for 7am?")
    XCTAssertTrue(reply("Sign in to Luna AI").waitForExistence(timeout: 10))
    XCTAssertTrue(reply("New reminder").exists)
    XCTAssertFalse(reply("New alarm").exists)
    XCTAssertTrue(reply("15:00").exists)
    XCTAssertFalse(app.buttons["Add"].exists, "a question prepares nothing")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "capture-added").count, 1,
      "still the one reminder")
    XCTAssertTrue(app.buttons["capture-undo"].exists)
    XCTAssertTrue(app.buttons["capture-open"].exists)
  }

}

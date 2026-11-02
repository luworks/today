import XCTest

/// Not signed in to Luna AI (TodayMock's default): the rules' local previews and native write gates.
@MainActor
final class AIAnnualCheckTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = TestData.fixtureArguments("ai-context-ui.json")
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
  }

  private func send(_ text: String) {
    let input = app.textViews["Ask AI or add anything"].firstMatch
    let field = input.exists ? input : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(text)
    app.buttons["ask-send"].tap()
    XCTAssertTrue(app.buttons["ask-send"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Thinking…"].waitForNonExistence(timeout: 15))
  }

  private func assertBookingPreview(_ action: String) {
    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 15))
    let title = app.buttons["capture-title"].label
    XCTAssertTrue(title.contains(action), title)
    let year = Calendar.current.component(.year, from: Date()) + 1
    XCTAssertTrue(title.contains(String(year)), title)
    XCTAssertTrue(app.staticTexts["No date"].exists)
    XCTAssertTrue(app.buttons["capture.kind.task"].isSelected)
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists)
    XCTAssertFalse(app.buttons["capture-undo"].exists)
  }

  func testExactBookingMonthRequiresAddAndSupportsUndo() {
    send("明年8月 预约医生做 annual check")
    assertBookingPreview("预约医生做 annual check")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Exact annual check - rules preview before Add"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Add"].tap()
    XCTAssertTrue(app.buttons["capture-open"].waitForExistence(timeout: 5))
    app.buttons["capture-open"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      (app.textFields["task.title"].value as? String ?? "").contains("预约医生做 annual check"))
    // The compact editor may lead to the existing full form after the editor branch integrates.
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    XCTAssertEqual(app.switches["Deadline"].value as? String, "0")
    // SwiftUI's populated vertical field exposes inconsistent TextField/TextView types.
    // Match the original request in its actual value rather than the empty placeholder.
    let notes = app.descendants(matching: .any).matching(
      NSPredicate(format: "value CONTAINS %@", "明年8月 预约医生做 annual check")
    ).firstMatch
    XCTAssertTrue((notes.value as? String ?? "").contains("明年8月 预约医生做 annual check"))
    app.buttons["Cancel"].tap()
    app.buttons["capture-undo"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["capture-undone"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["capture-add-again"].exists)
  }

  /// Not signed in, a report or a question gets no rule preview: the AI is unavailable and the draft goes back.
  func testBookedReportAndQuestionDoNotPrepareAnotherTask() {
    ask("明年8月 我已经预约医生做 annual check 了", expecting: "需要登录 Luna AI")
    app.buttons["Close"].firstMatch.tap()
    app.buttons["Ask AI or add anything"].tap()
    ask("Next August how do I book a doctor?", expecting: "Sign in to Luna AI")
  }

  /// Sends text the rules can't preview: the reply says why, and the draft is back in the composer.
  private func ask(_ text: String, expecting reply: String) {
    let input = app.textViews["Ask AI or add anything"].firstMatch
    let field = input.exists ? input : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(text)
    app.buttons["ask-send"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", reply)).firstMatch
        .waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["ask-send"].exists, "the draft is back in the composer")
    XCTAssertFalse(app.buttons["Add"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["capture-stack"].exists)
  }
}

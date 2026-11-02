import XCTest

/// The AI page keeps its context between messages: an answer completes the open card instead of starting a new item.
/// Clear requests are added right after the reply (owner decision 2026-11-02), so the open card here is an alarm
/// that still needs its time.
@MainActor
final class AskMultiTurnTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
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

  private func label(containing s: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
  }

  func testFollowUpChangesTheTimeOnTheSameCard() {
    send("make a alarm")
    let add = app.buttons["Add"]
    XCTAssertTrue(add.waitForExistence(timeout: 90))
    XCTAssertFalse(add.isEnabled, "an alarm without a time waits")
    XCTAssertTrue(
      label(containing: "What time should the alarm ring?").waitForExistence(timeout: 10),
      "the reply asks for the missing time")
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists)
    send("4pm")
    XCTAssertTrue(
      app.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 10),
      "the answer completes the same card, now Added")
    XCTAssertTrue(label(containing: "16:00").exists, "with the answered time")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "capture-stack").count, 1,
      "same item, not a new one called “4pm”")
    XCTAssertFalse(app.buttons["Add"].exists, "nothing waits for Add")
    XCTAssertTrue(
      label(containing: "Added the alarm").waitForExistence(timeout: 5), "the reply is a receipt")
    XCTAssertTrue(app.buttons["capture-undo"].exists)
  }
}

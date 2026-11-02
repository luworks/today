import XCTest

/// The AI page keeps its context between messages: a follow-up edits the open preview instead of starting a new item.
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
    send("Call Alex tomorrow at 3pm every week")
    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 90))
    send("make it 4pm")
    XCTAssertTrue(
      label(containing: "16:00").waitForExistence(timeout: 10), "the card now says 16:00")
    XCTAssertTrue(
      label(containing: "Call Alex").exists, "same item, not a new one called “make it 4pm”")
    XCTAssertEqual(app.buttons.matching(identifier: "Add").count, 1, "still one card")
    app.buttons["Add"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 5),
      "the card stays, now Added")
    XCTAssertTrue(
      label(containing: "Call Alex").exists && label(containing: "16:00").exists,
      "with the edited time")
  }

  func testFollowUpMakesItAnAlarm() {
    send("Call Alex tomorrow at 3pm every week")
    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 90))
    send("make it an alarm")
    XCTAssertTrue(label(containing: "Alarm ").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "New alarm").exists, "the card is an alarm now")
  }
}

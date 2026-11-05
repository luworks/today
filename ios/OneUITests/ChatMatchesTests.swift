import XCTest

/// Typing in Chat lists the existing items that match, so Chat doubles as search. Sample data, no Apple services.
@MainActor
final class ChatMatchesTests: XCTestCase {
  func testTypingListsMatchesAndTapOpensTheReminder() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting"]
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
    let field = app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("design review")
    let match = app.buttons.matching(identifier: "ask.match")
      .matching(NSPredicate(format: "label CONTAINS %@", "Write up design review notes")).firstMatch
    XCTAssertTrue(match.waitForExistence(timeout: 3), "the reminder is listed while typing")
    match.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5),
      "tap opens it")
  }
}

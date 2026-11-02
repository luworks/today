import XCTest

/// Your messages have a copy button (it confirms with a check mark); the app's own status sentences (a preview's
/// heading, "Added.") do not.
@MainActor
final class MessageCopyTests: XCTestCase {
  func testEachMessageHasACopyButtonThatConfirms() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting"]
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
    let f = app.textViews["Ask AI or add anything"].firstMatch
    let field = f.exists ? f : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("What's on today?\n")

    let copy = app.buttons.matching(identifier: "message.copy")
    expectation(for: NSPredicate(format: "count >= 1"), evaluatedWith: copy)
    waitForExpectations(timeout: 10)

    copy.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))
  }

  /// The app's own status sentences have no Copy button; your own message does.
  func testStatusSentencesHaveNoCopyButton() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting"]
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
    let f = app.textViews["Ask AI or add anything"].firstMatch
    let field = f.exists ? f : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    // Explicit recurrence keeps the Add preview (not signed in: the rules' local preview).
    field.typeText("Order printer paper tomorrow at 3pm every week\n")

    XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10), "the preview card is up")
    XCTAssertTrue(
      app.staticTexts[
        "Not signed in to Luna AI, so this preview comes from the rules. Nothing is added until you tap Add."
      ].exists)
    XCTAssertEqual(
      app.buttons.matching(identifier: "message.copy").count, 1, "only your own message has Copy")
  }
}

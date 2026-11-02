import XCTest

/// Your messages have a copy button (it confirms with a check mark); the app's own status sentences (the rules'
/// lead-in, the "Added …" receipt) do not.
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
    // Not signed in: the rules read it and add it at once, with a receipt.
    field.typeText("Order printer paper tomorrow at 3pm every week\n")

    XCTAssertTrue(
      app.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 10),
      "the card is up, Added")
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(
          format: "label BEGINSWITH %@ AND label CONTAINS %@",
          "Not signed in to Luna AI, so the rules read this.",
          "Added the reminder “Order printer paper”. Tap Undo if you don't want it.")
      ).firstMatch.waitForExistence(timeout: 5), "the status sentence is the rules' receipt")
    XCTAssertEqual(
      app.buttons.matching(identifier: "message.copy").count, 1, "only your own message has Copy")
  }
}

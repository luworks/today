import XCTest

/// A reply that arrives late (`-uiTestingAgentScript slow-reply`: the scripted agent answers after 12 s) must not move
/// the earlier message the user scrolled up to read; the user's own next Send follows the end again.
@MainActor
final class AskReadingPositionTests: XCTestCase {
  func testDelayedReplyAndCardPreserveUserReadingThenSendFollowsTail() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments =
      TestData.fixtureArguments("ask-reading-history.json") + [
        "-uiTestingAgentScript", "slow-reply",
      ]
    app.launch()
    app.openSidebar()
    app.buttons["Ask reading history"].firstMatch.tap()
    let field = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("How can I stay focused?\n")
    let scroll = app.scrollViews.allElementsBoundByIndex.max {
      $0.frame.height < $1.frame.height
    }!
    XCTAssertGreaterThan(
      scroll.frame.height, 200, "Select the conversation, not the 44pt composer scroll view")
    scroll.swipeDown(velocity: .fast)
    scroll.swipeDown(velocity: .fast)
    let earlier = scroll.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "History ")
    )
    .allElementsBoundByIndex.first { $0.isHittable && scroll.frame.contains($0.frame) }
    XCTAssertNotNil(earlier, "A real upward history pan must reveal an earlier message")
    guard let earlier else { return }
    let reply = app.staticTexts["This is a slow scripted answer. Nothing was changed."]
    XCTAssertFalse(reply.exists, "The scripted answer must still be pending after the real pan")
    let before = earlier.frame.minY
    // Wait beyond the 12 s delay; this tests a real gesture, not setContentOffset. The list is lazy, so the answer
    // below the fold may not be in the tree until the chat scrolls back to the end.
    _ = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: reply)
      ], timeout: 16)
    XCTAssertTrue(earlier.isHittable)
    XCTAssertEqual(
      earlier.frame.minY, before, accuracy: 35,
      "A delayed reply must preserve the message being read")
    field.tap()
    field.typeText("Thanks\n")
    XCTAssertTrue(app.staticTexts["Thanks"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Thanks"].isHittable, "Own Send resumes following the end")
    XCTAssertTrue(reply.exists, "the delayed answer arrived above it")
  }
}

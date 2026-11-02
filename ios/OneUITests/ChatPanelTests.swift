import XCTest

/// Chat is a full-screen page (like ChatGPT). The bottom field starts a new conversation every time; Close goes back
/// to the page, the conversation stays in the sidebar and an unsent draft is dropped with it.
@MainActor
final class ChatPanelTests: XCTestCase {
  func testTapToUsableComposerEvidence() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-performanceTrace"]
    app.launch()
    let button = app.buttons["Ask AI or add anything"]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    let start = ProcessInfo.processInfo.systemUptime
    button.tap()
    let field = app.textViews["ask-input"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 5), "a new chat is ready to type")
    field.typeText("Unsent draft")
    XCTAssertEqual(field.value as? String, "Unsent draft")
    print(
      "CHAT_UI tap_call_to_verified_text_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) includes_XCTest_lookup_idle_tap_and_typing=true"
    )
    // Full screen: the page's bottom bar and tabs are covered, the menu and Close are at the top.
    XCTAssertFalse(button.isHittable)
    XCTAssertFalse(app.buttons["Today"].firstMatch.isHittable)
    let menu = app.buttons["chat.menu"]
    let close = app.buttons["Close"]
    XCTAssertTrue(menu.isHittable)
    XCTAssertTrue(close.isHittable)
    XCTAssertLessThan(close.frame.maxY, app.frame.midY)
    XCTAssertGreaterThan(field.frame.minY, app.frame.midY)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Full-screen Chat with keyboard and unsent draft"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testEveryOpenStartsANewChatAndKeepsThePastOne() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-performanceTrace"]
    app.launch()
    let chat = app.buttons["Ask AI or add anything"]
    chat.tap()
    let field = app.textViews["ask-input"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText("Hello\n")
    XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 5))
    // Not signed in to Luna AI (TodayMock): a greeting gets the "sign in" answer and its draft back.
    let reply = app.staticTexts.containing(
      NSPredicate(format: "label BEGINSWITH %@", "Sign in to Luna AI")
    )
    .firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 8))
    let draft = "Unsent: call Alex at 3pm — 中文草稿"
    field.typeText(draft)
    app.buttons["Close"].firstMatch.tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    XCTAssertTrue(chat.isHittable, "Close goes back to the page")
    XCTAssertTrue(app.buttons["Today"].firstMatch.isSelected)

    chat.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["What do you want to plan?"].exists, "a new, empty chat")
    XCTAssertFalse(app.staticTexts["Hello"].exists)
    XCTAssertFalse(reply.exists)
    XCTAssertNotEqual(field.value as? String, draft, "the unsent draft is not carried over")
    XCTAssertFalse(app.staticTexts[draft].exists, "the draft was never sent")
    XCTAssertFalse(app.buttons["capture-open"].exists)
    XCTAssertFalse(app.buttons["Add"].exists)

    // Chat's menu opens the sidebar, where the first conversation is kept and reopens.
    app.buttons["chat.menu"].tap()
    let row = app.buttons.matching(
      NSPredicate(format: "identifier == 'conversation.row' AND label == 'Hello'")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "the past chat is in the sidebar")
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier == 'conversation.row'")).count, 1,
      "opening and closing an empty chat saves nothing")
    row.tap()
    XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 5))
    XCTAssertTrue(reply.exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Past chat reopened from the sidebar"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testLargeTextKeepsComposerAndCloseReachable() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    app.buttons["Ask AI or add anything"].tap()
    let input = app.textViews["ask-input"].firstMatch
    let close = app.buttons["Close"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertTrue(input.isHittable)
    XCTAssertTrue(close.isHittable)
    XCTAssertGreaterThan(close.frame.minY, app.frame.minY + 50)
    XCTAssertGreaterThan(input.frame.minX, app.frame.minX)
    XCTAssertLessThan(input.frame.maxX, app.frame.maxX)
    input.typeText("Large text draft")
    XCTAssertEqual(input.value as? String, "Large text draft")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Accessibility text full-screen Chat with keyboard"
    shot.lifetime = .keepAlways
    add(shot)
    close.tap()
    XCTAssertTrue(app.buttons["Ask AI or add anything"].isHittable)
  }
}

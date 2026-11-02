import XCTest

/// Three journeys not signed in to Luna AI (TodayMock): FastLane previews and continuations, no scripted model.
@MainActor
final class AIRecurringReminderTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.fixtureArguments("ai-context-ui.json")
      app.launch()
      app.openSidebar()
      let newChat = app.buttons["New chat"]
      XCTAssertTrue(newChat.waitForExistence(timeout: 5))
      newChat.tap()
    }
  }

  func testDirectChineseSundayPreparesReminderWithoutWriting() {
    send("每周日下午5点提醒我丢垃圾")
    assertPreview("丢垃圾", repeatLabel: "Every Sun", hour: 17)
    keepScreenshot("Sunday trash reminder awaits Add")
    assertNoPlannerWrites()
  }

  func testFridaySundaySurviveAddAndEditorSaveReopen() {
    send("添加一个reminder：每周五、每周日下午5点提醒我丢垃圾")
    assertPreview("丢垃圾", repeatLabel: "Every Fri, Sun", hour: 17)
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists)
    preview.buttons["Add"].tap()
    let open = app.buttons["capture-open"].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    open.tap()
    assertSavedEditor()
    keepScreenshot("Saved Friday and Sunday repeat selection")
    app.buttons["task.save"].tap()
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    open.tap()
    assertSavedEditor()
    app.buttons["Cancel"].tap()
  }

  private var preview: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(.button, identifier: "Add").firstMatch
  }
  private var field: XCUIElement {
    let input = app.textViews["Ask AI or add anything"].firstMatch
    return input.exists ? input : app.textViews.firstMatch
  }
  private func send(_ text: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(text)
    let send = app.buttons["ask-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.tap()
    XCTAssertTrue(send.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Thinking…"].waitForNonExistence(timeout: 15))
  }
  private func assertPreview(_ title: String, repeatLabel: String, hour: Int) {
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 15))
    XCTAssertTrue(preview.staticTexts["New reminder"].exists)
    let titleButton = preview.buttons["capture-title"].firstMatch
    XCTAssertTrue(titleButton.waitForExistence(timeout: 5))
    XCTAssertEqual(titleButton.label, title)
    XCTAssertTrue(
      preview.staticTexts.containing(
        NSPredicate(
          format: "label CONTAINS %@ AND label CONTAINS %@", repeatLabel, formattedTime(hour))
      ).firstMatch.exists)
    XCTAssertEqual(app.buttons.matching(identifier: "Add").count, 1)
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists)
  }
  private func assertSavedEditor() {
    let title = app.textFields["task.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "丢垃圾")
    // Exercise a real edit so Save commits the preserved custom weekdays.
    (app.buttons["Flag"].exists ? app.buttons["Flag"] : app.buttons["Unflag"]).tap()
    app.buttons["task.more"].tap()
    let repeatSelection = app.buttons.containing(
      NSPredicate(format: "label CONTAINS %@", "Every Fri, Sun")
    ).firstMatch
    if !repeatSelection.isHittable { app.swipeUp() }
    XCTAssertTrue(
      repeatSelection.waitForExistence(timeout: 5),
      "Saved model and editor selection retain BOTH weekdays")
  }
  private func formattedTime(_ hour: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeStyle = .short
    return formatter.string(
      from: Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!)
  }
  private func assertNoPlannerWrites() {
    app.buttons["Close"].firstMatch.tap()
    // Activity lives in the sidebar: open it from the page's menu button.
    let menu = app.buttons["Open menu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    let activity = app.buttons["Activity"].firstMatch
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    activity.tap()
    XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 5))
  }
  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

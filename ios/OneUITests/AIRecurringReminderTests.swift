import XCTest

/// Not signed in to Luna AI (TodayMock): the rules read a recurring reminder and add it right after the reply, with
/// Undo and Open (owner decision 2026-11-02); no scripted model.
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

  /// A clear recurring request is written at once; Undo on its card takes it back.
  func testDirectChineseSundayPreparesReminderWithoutWriting() {
    send("每周日下午5点提醒我丢垃圾")
    assertAdded("丢垃圾", repeatLabel: "Every Sun", hour: 17)
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已添加提醒“丢垃圾”"))
        .firstMatch.waitForExistence(timeout: 5), "the reply is a receipt")
    keepScreenshot("Sunday trash reminder added with Undo")
    card.buttons["capture-undo"].tap()
    XCTAssertTrue(
      card.descendants(matching: .any)["capture-undone"].waitForExistence(timeout: 5),
      "Undo removes the reminder")
    XCTAssertTrue(card.buttons["capture-add-again"].exists)
    assertActivityRecordsTheWrite()
  }

  func testFridaySundaySurviveAddAndEditorSaveReopen() {
    send("添加一个reminder：每周五、每周日下午5点提醒我丢垃圾")
    assertAdded("丢垃圾", repeatLabel: "Every Fri, Sun", hour: 17)
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

  /// The newest capture card (earlier ones stay in the chat).
  private var card: XCUIElement {
    let stacks = app.descendants(matching: .any).matching(identifier: "capture-stack")
    return stacks.element(boundBy: max(stacks.count - 1, 0))
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
  /// The request was written right after the reply: one Added card with Undo and Open, no Add.
  private func assertAdded(_ title: String, repeatLabel: String, hour: Int) {
    XCTAssertTrue(card.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 15))
    XCTAssertTrue(card.staticTexts["New reminder"].exists)
    let titleButton = card.buttons["capture-title"].firstMatch
    XCTAssertTrue(titleButton.waitForExistence(timeout: 5))
    XCTAssertEqual(titleButton.label, title)
    XCTAssertTrue(
      card.staticTexts.containing(
        NSPredicate(
          format: "label CONTAINS %@ AND label CONTAINS %@", repeatLabel, formattedTime(hour))
      ).firstMatch.exists)
    XCTAssertTrue(card.buttons["capture-undo"].exists)
    XCTAssertTrue(card.buttons["capture-open"].exists)
    XCTAssertFalse(app.buttons["Add"].exists, "nothing waits for Add")
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "capture-added").count, 1)
  }
  private func assertSavedEditor() {
    let title = app.descendants(matching: .any)["task.title"].firstMatch
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
  /// The write (and its Undo) is in the Activity ledger.
  private func assertActivityRecordsTheWrite() {
    app.buttons["Close"].firstMatch.tap()
    // Activity lives in the sidebar: open it from the page's menu button.
    let menu = app.buttons["Open menu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    let activity = app.buttons["Activity"].firstMatch
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    activity.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "activity.row").firstMatch
        .waitForExistence(timeout: 5), "the reminder's creation is recorded")
  }
  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

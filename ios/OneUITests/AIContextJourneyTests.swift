import XCTest

/// Not signed in to Luna AI (TodayMock, -uiTesting): FastLane previews and continuations, no scripted model.
@MainActor
final class AIContextJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let storedThread = "Dinner alarm context"

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.fixtureArguments("ai-context-ui.json")
      app.launch()
    }
  }

  func testChineseScreenshotSequencePreservesDinnerAlarmContext() {
    openNewChat()
    // Explicit recurrence keeps this alarm-conversion journey behind Add.
    send("今天晚上6点的时候吧，就提醒我一定不能再吃饭了，每天")
    let title = assertPreview(
      titleContaining: "不能再吃饭", kind: "New reminder", day: "Today", hour: 18)
    keepScreenshot("Chinese U1 - dinner reminder at 6pm")

    send("没有，就是加个闹钟就可以")
    assertPreview(title: title, kind: "New alarm", day: "Today", hour: 18)
    keepScreenshot("Chinese U2 - same dinner title and time as alarm")

    send("我需要你来帮我设定闹钟哦")
    assertPreview(title: title, kind: "New alarm", day: "Today", hour: 18)
    keepScreenshot("Chinese U3 - alarm still awaits Add")
    assertNoPlannerWrites()
  }

  func testEnglishAlarmClarificationAndDateTimeCorrectionsPreserveTitle() {
    openNewChat()
    send("At 6pm tonight, remind me not to eat dinner again every day.")
    let title = assertPreview(
      titleContaining: "Do not eat dinner again", kind: "New reminder", day: "Today", hour: 18)
    send("No, just add an alarm.")
    assertPreview(title: title, kind: "New alarm", day: "Today", hour: 18)
    send("I need you to help me set that alarm.")
    assertPreview(title: title, kind: "New alarm", day: "Today", hour: 18)
    send("Make it tomorrow instead.")
    assertPreview(title: title, kind: "New alarm", day: "Tomorrow", hour: 18)
    send("Actually, 7pm.")
    assertPreview(title: title, kind: "New alarm", day: "Tomorrow", hour: 19)
    assertNoPlannerWrites()
  }

  func testNewChatClearsReferenceAndStoredThreadResumesUserContext() {
    openStoredThread()
    // The fixture contains text history, not a stored capture card. This turn must recover user context.
    send("I need you to help me set that alarm.")
    let title = assertPreview(
      titleContaining: "Do not eat dinner again", kind: "New alarm", day: "Today", hour: 18)
    XCTAssertFalse(
      previewTitle.label.localizedCaseInsensitiveContains("watering plants"),
      "An assistant aside must not replace the user's dinner request")

    closeChatToSidebar()
    app.buttons["New chat"].tap()
    XCTAssertTrue(app.staticTexts["What do you want to plan?"].waitForExistence(timeout: 5))
    send("I need you to help me set that alarm.")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "What time")).firstMatch
        .waitForExistence(timeout: 10),
      "A new thread asks for its own time instead of inheriting the dinner request")
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 10))
    XCTAssertTrue(preview.staticTexts["New alarm"].exists)
    XCTAssertFalse(preview.buttons["Add"].isEnabled, "An alarm without a time cannot be added")
    XCTAssertEqual(previewTitle.label, "Alarm", "The new thread has a generic alarm title")
    XCTAssertNotEqual(previewTitle.label, title, "The dinner title stays in its own thread")
    XCTAssertFalse(
      preview.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", formattedTime(18)))
        .firstMatch.exists,
      "The new thread cannot borrow the old thread's 6pm time")
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists)
    XCTAssertEqual(app.buttons.matching(identifier: "Add").count, 1)

    closeChatToSidebar()
    tapStoredThread()
    send("Actually, make it 7pm tomorrow.")
    assertPreview(title: title, kind: "New alarm", day: "Tomorrow", hour: 19)
    assertNoPlannerWrites()
  }

  private var preview: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(.button, identifier: "Add").firstMatch
  }

  private var previewTitle: XCUIElement { preview.buttons["capture-title"].firstMatch }

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
    XCTAssertTrue(send.waitForNonExistence(timeout: 5), "The composer submitted the turn")
    XCTAssertTrue(app.staticTexts["Thinking…"].waitForNonExistence(timeout: 15))
  }

  private func openNewChat() {
    app.openSidebar()
    let button = app.buttons["New chat"]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 5))
  }

  private func openStoredThread() {
    app.openSidebar()
    tapStoredThread()
  }

  private func tapStoredThread() {
    let thread = app.buttons[storedThread]
    XCTAssertTrue(thread.waitForExistence(timeout: 5))
    thread.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 5))
  }

  private func closeChatToSidebar() {
    app.buttons["Close"].firstMatch.tap()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
  }

  @discardableResult
  private func assertPreview(
    titleContaining fragment: String, kind: String, day: String, hour: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let title = previewTitle
    XCTAssertTrue(
      title.waitForExistence(timeout: 15), "The capture card exposes its editable title",
      file: file, line: line)
    let value = title.label
    XCTAssertTrue(
      value.localizedCaseInsensitiveContains(fragment),
      "The capture card contains the user's intended title: \(value)", file: file, line: line)
    assertPreview(title: value, kind: kind, day: day, hour: hour, file: file, line: line)
    return value
  }

  private func assertPreview(
    title: String, kind: String, day: String, hour: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(preview.buttons["Add"].waitForExistence(timeout: 15), file: file, line: line)
    XCTAssertTrue(preview.staticTexts[kind].waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertEqual(
      previewTitle.label, title, "The full title survives the correction", file: file, line: line)
    let summary = preview.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", day, formattedTime(hour))
    ).firstMatch
    XCTAssertTrue(
      summary.waitForExistence(timeout: 10), "The card preserves the requested day and time",
      file: file, line: line)
    XCTAssertEqual(
      app.buttons.matching(identifier: "Add").count, 1, "Only one proposal awaits approval",
      file: file, line: line)
    XCTAssertFalse(app.descendants(matching: .any)["capture-added"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["capture-undo"].exists, file: file, line: line)
  }

  private func formattedTime(_ hour: Int) -> String {
    let time = DateFormatter()
    time.locale = .autoupdatingCurrent
    time.dateStyle = .none
    time.timeStyle = .short
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    return time.string(from: date)
  }

  private func assertNoPlannerWrites() {
    // Activity shows change-ledger rows, not AI interaction telemetry. No Add has been tapped in this journey.
    closeChatToSidebar()
    let activity = app.buttons["Activity"].firstMatch
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    activity.tap()
    XCTAssertTrue(
      app.staticTexts["No activity yet"].waitForExistence(timeout: 5),
      "Clarifications and corrections must not write planner changes before Add")
  }

  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

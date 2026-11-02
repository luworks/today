import XCTest

/// Not signed in to Luna AI (TodayMock, -uiTesting): FastLane reads requests and continuations, no scripted model.
/// A clear request is added right after the reply with Undo (owner decision 2026-11-02); an alarm without a time
/// waits on an open card and asks for it.
@MainActor
final class AIContextJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let storedThread = "Dinner alarm context"

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      // A fixed morning clock: "今天晚上6点" / "6pm tonight" must still be ahead.
      app.launchArguments =
        TestData.fixtureArguments("ai-context-ui.json") + ["-uiTestingNow", "09:11"]
      app.launch()
    }
  }

  /// The Chinese dinner request keeps its full title and its evening time, and is added at once with Undo.
  func testChineseScreenshotSequencePreservesDinnerAlarmContext() {
    openNewChat()
    send("今天晚上6点的时候吧，就提醒我一定不能再吃饭了，每天")
    assertAdded(titleContaining: "不能再吃饭", kind: "New reminder", day: "Today", hour: 18)
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "不需要的话点撤销"))
        .firstMatch.waitForExistence(timeout: 5), "the reply is a receipt in Chinese")
    keepScreenshot("Chinese U1 - dinner reminder at 6pm added")
    undoAndAssertUndone()
    assertActivityRecordsTheWrite()
  }

  func testNewChatClearsReferenceAndStoredThreadResumesUserContext() {
    openStoredThread()
    // The fixture contains text history, not a stored capture card. This turn must recover user context.
    send("I need you to help me set that alarm.")
    let title = assertAdded(
      titleContaining: "Do not eat dinner again", kind: "New alarm", day: "Today", hour: 18)
    XCTAssertFalse(
      title.localizedCaseInsensitiveContains("watering plants"),
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
    XCTAssertEqual(
      preview.buttons["capture-title"].firstMatch.label, "Alarm",
      "The new thread has a generic alarm title")
    XCTAssertNotEqual(
      preview.buttons["capture-title"].firstMatch.label, title,
      "The dinner title stays in its own thread")
    XCTAssertFalse(
      preview.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", formattedTime(18)))
        .firstMatch.exists,
      "The new thread cannot borrow the old thread's 6pm time")
    XCTAssertNil(
      hittable("capture-added", in: app.descendants(matching: .any)),
      "Nothing is added in the new thread")
    // Only this thread offers an Add (the closed thread stays built, hidden).
    XCTAssertEqual(
      app.buttons.matching(identifier: "Add").allElementsBoundByIndex.filter(\.isHittable).count, 1)

    // The stored thread still shows its own alarm, Added; Undo takes it back.
    closeChatToSidebar()
    tapStoredThread()
    undoAndAssertUndone()
  }

  /// The open card of the visible thread (an alarm still waiting for its time).
  private var preview: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(.button, identifier: "Add").firstMatch
  }

  /// The first hittable element with `identifier` (closed threads stay built, hidden).
  private func hittable(_ identifier: String, in query: XCUIElementQuery) -> XCUIElement? {
    query.matching(identifier: identifier).allElementsBoundByIndex.first(where: \.isHittable)
  }

  /// The visible thread's Added card.
  private var addedCard: XCUIElement {
    let stacks = app.descendants(matching: .any).matching(identifier: "capture-stack")
      .containing(.button, identifier: "capture-undo")
    return stacks.allElementsBoundByIndex.last(where: \.isHittable) ?? stacks.firstMatch
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

  /// Undo on the visible thread's Added card removes the item: the card says Undone.
  private func undoAndAssertUndone(file: StaticString = #filePath, line: UInt = #line) {
    let undo = addedCard.buttons["capture-undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10), file: file, line: line)
    undo.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "capture-undone").firstMatch
        .waitForExistence(timeout: 5), "Undo removes it", file: file, line: line)
  }

  private func closeChatToSidebar() {
    app.buttons["Close"].firstMatch.tap()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
  }

  /// The request was added right after the reply: one Added card with the intended title, kind, day and time.
  @discardableResult
  private func assertAdded(
    titleContaining fragment: String, kind: String, day: String, hour: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let card = addedCard
    XCTAssertTrue(
      card.descendants(matching: .any)["capture-added"].waitForExistence(timeout: 15),
      "The request is added at once", file: file, line: line)
    let title = card.buttons["capture-title"].firstMatch
    XCTAssertTrue(
      title.waitForExistence(timeout: 5), "The card exposes its editable title",
      file: file, line: line)
    let value = title.label
    XCTAssertTrue(
      value.localizedCaseInsensitiveContains(fragment),
      "The card contains the user's intended title: \(value)", file: file, line: line)
    XCTAssertTrue(card.staticTexts[kind].waitForExistence(timeout: 10), file: file, line: line)
    let summary = card.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", day, formattedTime(hour))
    ).firstMatch
    XCTAssertTrue(
      summary.waitForExistence(timeout: 10), "The card preserves the requested day and time",
      file: file, line: line)
    XCTAssertTrue(card.buttons["capture-open"].exists, file: file, line: line)
    XCTAssertEqual(
      app.buttons.matching(identifier: "Add").allElementsBoundByIndex.filter(\.isHittable).count,
      0, "Nothing waits for Add", file: file, line: line)
    return value
  }

  private func formattedTime(_ hour: Int) -> String {
    let time = DateFormatter()
    time.locale = .autoupdatingCurrent
    time.dateStyle = .none
    time.timeStyle = .short
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    return time.string(from: date)
  }

  /// Activity shows change-ledger rows: the request's write (and its Undo) is there.
  private func assertActivityRecordsTheWrite() {
    closeChatToSidebar()
    let activity = app.buttons["Activity"].firstMatch
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    if !activity.isHittable { app.openSidebar() }
    activity.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "activity.row").firstMatch
        .waitForExistence(timeout: 5), "The added item is recorded in Activity")
  }

  private func keepScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

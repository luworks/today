import XCTest

/// One tap opens exactly one editor: no second sheet underneath, nothing left behind after Cancel.
/// (A sheet on the row plus one on the list, or a tap handler plus a menu action, would stack two.)
/// Also: long-press an empty slot on the 2 Day grid to make an event there, like Apple Calendar.
/// Uses the test dataset (tests/fixtures/today-dataset.json). Set TEST_RUNNER_PRESENT_SHOTS=<folder> for screenshots.
@MainActor
final class SinglePresentationTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.launchArguments
      app.launch()
    }
  }

  private func shot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["PRESENT_SHOTS"] else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? XCUIScreen.main.screenshot().pngRepresentation.write(
      to: URL(fileURLWithPath: dir + "/" + name + ".png"))
  }

  private func labeled(_ prefix: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
      .firstMatch
  }

  /// After `open`, exactly one editor (one navigation bar) is up; one Cancel closes it and nothing is underneath.
  private func assertOpensOneEditor(
    _ name: String, cancel: String = "Cancel", open: () -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      app.navigationBars.count, 0, "nothing is open before the tap", file: file, line: line)
    open()
    XCTAssertTrue(
      app.navigationBars.firstMatch.waitForExistence(timeout: 5), "an editor opens", file: file,
      line: line)
    sleep(1)  // a second, late presentation would land by now
    shot(name)
    XCTAssertEqual(
      app.navigationBars.count, 1, "exactly one editor: \(app.navigationBars.debugDescription)",
      file: file, line: line)
    app.buttons[cancel].firstMatch.tap()
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == 0"), object: app.navigationBars)
    XCTAssertEqual(
      XCTWaiter().wait(for: [gone], timeout: 5), .completed,
      "one Cancel closes it; no second editor underneath",
      file: file, line: line)
  }

  func testTappingAnEventInTwoDayOpensOneEditor() {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.twoday"].tap()
    let block = labeled("Product sync")
    XCTAssertTrue(block.waitForExistence(timeout: 5))
    assertOpensOneEditor("week-event") { block.tap() }
  }

  func testTappingAnEventInMonthOpensOneEditor() {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.month"].tap()
    let row = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH 'Product sync'")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    assertOpensOneEditor("month-event") { row.tap() }
  }

  func testTappingAnEventOnTodayOpensOneEditor() {
    let row = labeled("Product sync")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    assertOpensOneEditor("today-event") { row.tap() }
  }

  func testTappingAReminderOpensOneEditor() {
    let row = app.staticTexts["Buy milk"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    let editor = app.descendants(matching: .any)["task.title"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "the compact reminder editor opens")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "task.title").count, 1,
      "exactly one reminder editor")
    XCTAssertEqual(editor.value as? String, "Buy milk")
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "one Cancel closes every reminder editor")
    XCTAssertFalse(app.buttons["Cancel"].exists, "no second editor remains underneath")
    XCTAssertTrue(row.isHittable, "the original Today row accepts input again")
  }

  func testTappingAReminderInAListOpensOneEditor() {
    app.buttons["Reminders"].firstMatch.tap()
    let home = app.buttons["list.Home"].firstMatch
    XCTAssertTrue(home.waitForExistence(timeout: 5))
    home.tap()
    let row = app.staticTexts["Buy milk"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    // The list screen is pushed: it has its own navigation bar, so count from there.
    let before = app.navigationBars.count
    row.tap()
    sleep(2)
    shot("list-reminder")
    XCTAssertEqual(app.navigationBars.count, before + 1, "exactly one editor over the list")
  }

  /// The alarm editor is Clock's sheet: its title is text, not a navigation bar.
  func testTappingAnAlarmOpensOneEditor() {
    app.buttons["Clock"].firstMatch.tap()
    let row = app.buttons.matching(identifier: "alarm.row").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    let title = app.staticTexts["Edit Alarm"]
    XCTAssertTrue(title.waitForExistence(timeout: 5), "the alarm editor opens")
    sleep(1)
    shot("alarm")
    XCTAssertEqual(
      app.staticTexts.matching(identifier: "Edit Alarm").count, 1, "exactly one alarm editor")
    app.buttons["Cancel"].firstMatch.tap()
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: title)
    XCTAssertEqual(
      XCTWaiter().wait(for: [gone], timeout: 5), .completed,
      "one Cancel closes it; nothing underneath")
  }

  // MARK: Long-press to make an event

  /// Where a time is in today's column: measured from the 09:00 "Product sync" block (48pt per hour).
  private func todaySlot(minutesAfterNine: Double) -> XCUICoordinate {
    let block = labeled("Product sync")
    XCTAssertTrue(block.waitForExistence(timeout: 5))
    let f = block.frame
    return app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: f.minX + 4, dy: f.minY + minutesAfterNine / 60 * 48))
  }

  private func showTwoDay() {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.twoday"].tap()
    XCTAssertTrue(app.buttons["calendar.mode.twoday"].waitForSelected())
    XCTAssertTrue(labeled("Product sync").waitForExistence(timeout: 5))
    sleep(2)  // the grid scrolls to 7:00 when it appears; measure after that
  }

  /// Press and hold an empty slot (10:40, between Standup, whose short block reaches past 10:00, and the 11:00
  /// "Renew parking permit"): the new-event editor opens at 10:30-11:30.
  func testLongPressOnAnEmptySlotMakesAnEventThere() {
    showTwoDay()
    let slot = todaySlot(minutesAfterNine: 100)  // 10:40 snaps down to 10:30
    slot.press(forDuration: 0.8)
    let editor = app.navigationBars["New event"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "releasing opens the new-event editor")
    shot("longpress-editor")
    XCTAssertEqual(app.navigationBars.count, 1)
    XCTAssertTrue(
      app.buttons["10:30"].exists || labeled("10:30").exists, "starts at the pressed slot")
    XCTAssertTrue(app.buttons["11:30"].exists || labeled("11:30").exists, "and lasts an hour")
    app.buttons["Cancel"].tap()
    XCTAssertFalse(
      app.descendants(matching: .any)["calendar.newEventDraft"].waitForExistence(timeout: 1),
      "the placeholder is gone")
  }

  /// Hold an empty slot (10:40), then drag down an hour before letting go: the event starts where the finger ends (11:30).
  func testLongPressThenDragMovesTheNewEvent() {
    showTwoDay()
    let from = todaySlot(minutesAfterNine: 100)
    let to = from.withOffset(CGVector(dx: 0, dy: 48))
    from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    shot("longpress-drag-after")
    XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5))
    shot("longpress-drag-editor")
    XCTAssertTrue(
      app.buttons["11:30"].exists || labeled("11:30").exists, "starts where the finger was let go")
    XCTAssertTrue(app.buttons["12:30"].exists || labeled("12:30").exists)
    app.buttons["Cancel"].tap()
  }

  /// A long-press on an event shows its menu only: no new-event placeholder or editor on top of it.
  func testLongPressOnAnEventShowsOnlyItsMenu() {
    showTwoDay()
    labeled("Product sync").press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["Show Details"].waitForExistence(timeout: 5), "the event's menu")
    sleep(1)
    shot("longpress-event-menu")
    XCTAssertFalse(app.navigationBars["New event"].exists, "no new-event editor")
    XCTAssertFalse(
      app.descendants(matching: .any)["calendar.newEventDraft"].exists, "no placeholder")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()  // dismiss the menu
  }

  /// A quick tap on an empty slot does nothing, and a swipe still scrolls the grid (no editor, no placeholder).
  func testTapAndSwipeOnTheGridDoNotMakeAnEvent() {
    showTwoDay()
    todaySlot(minutesAfterNine: 100).tap()  // 10:40, empty (11:00 has "Renew parking permit")
    let block = labeled("Product sync")
    let y = block.frame.minY
    shot("swipe-before")
    app.swipeUp(velocity: .slow)
    sleep(2)
    shot("swipe-after")
    XCTAssertEqual(app.navigationBars.count, 0, "no editor")
    XCTAssertFalse(
      app.descendants(matching: .any)["calendar.newEventDraft"].exists, "no placeholder")
    XCTAssertNotEqual(block.frame.minY, y, "the grid scrolled")
  }

  // MARK: Year heatmap, day tints, pinch to zoom

  /// The Year view shades busy days; the current month reports how many (the dataset has events this week).
  func testYearShowsBusyDays() {
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.year"].tap()
    let c = Calendar.current.dateComponents([.year, .month], from: .now)
    let month = app.descendants(matching: .any)[
      String(format: "miniMonth.%04d-%02d", c.year!, c.month!)]
    XCTAssertTrue(month.waitForExistence(timeout: 5))
    sleep(1)
    shot("year-heatmap")
    XCTAssertTrue(
      (month.value as? String ?? "").contains("busy day"),
      "busy days are shaded: \(month.debugDescription)")
  }

  /// Screenshots of the quiet tints (weekends, days that are over) in 2 Day and Month.
  func testWeekAndMonthTints() {
    showTwoDay()
    shot("week-tints")
    app.buttons["calendar.mode.month"].tap()
    XCTAssertTrue(app.buttons["calendar.mode.month"].waitForSelected())
    shot("month-tints")
  }

  /// Pinching the 2 Day grid out makes hours taller; tapping an event still opens one editor afterwards.
  func testPinchZoomsTheWeekGrid() {
    showTwoDay()
    let block = labeled("Product sync")
    let before = block.frame.height
    app.windows.firstMatch.pinch(withScale: 2, velocity: 1)
    sleep(1)
    shot("week-zoomed")
    XCTAssertGreaterThan(
      block.frame.height, before * 1.3, "hours got taller (\(before) → \(block.frame.height))")
    assertOpensOneEditor("week-zoomed-tap") { block.tap() }
  }
}

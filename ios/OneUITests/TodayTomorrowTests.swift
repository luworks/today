import XCTest

/// Today supports week-strip navigation and the collapsed overdue and settled sections.
/// Synthetic dates follow the device calendar; no Apple services or user data are used.
@MainActor
final class TodayTomorrowTests: XCTestCase {
  private func launch(at time: String) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments =
      TestData.fixtureArguments("today-disclosure-sections.json") + [
        "-uiTestingNow", time, "-today.setting.jumpToNow", "NO",
        "-uiTestingPrefs", "showFreeTime=0",
      ]
    app.launch()
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 5))
    return app
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    let list = app.collectionViews.firstMatch
    for up in [true, false] {
      for _ in 0..<6 {
        var viewport = list.frame.intersection(app.frame).insetBy(dx: 0, dy: 8)
        let chat = app.buttons["Ask AI or add anything"]
        if chat.exists {
          viewport.size.height = min(viewport.maxY, chat.frame.minY) - viewport.minY
        }
        if element.exists, element.isHittable, element.isFullyVisible(in: viewport) { return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(
          CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (up ? 0.8 : 0.2)))
        let to = origin.withOffset(
          CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (up ? 0.2 : 0.8)))
        from.press(forDuration: 0.05, thenDragTo: to)
      }
    }
    XCTFail("Section control is outside the native List viewport: \(element)")
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The week strip on Today opens tomorrow in one tap; the bottom bar's Today button returns, with no extra row.
  func testWeekStripOpensTomorrowInOneTap() {
    let app = launch(at: "09:41")
    let cal = Calendar.current
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
    let c = cal.dateComponents([.year, .month, .day], from: tomorrow)
    let id = String(format: "weekStrip.%04d-%02d-%02d", c.year!, c.month!, c.day!)
    let next = app.buttons[id]
    if !next.exists {
      let start = app.weekStripDay(.now).coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
    }
    XCTAssertTrue(next.waitForExistence(timeout: 3))
    next.tap()
    XCTAssertTrue(next.waitForSelected(timeout: 3))
    XCTAssertFalse(app.weekStripDay(.now).isSelected, "only the shown day is selected")
    XCTAssertTrue(app.staticTexts["Tomorrow anytime task"].waitForExistence(timeout: 3))
    XCTAssertFalse(
      app.buttons["Back to today"].exists, "no Back to today row: the Today button is the way back")
    app.returnToToday()
    // Tapping it again on today keeps today.
    app.returnToToday()
  }

  func testWeekStripSwipesSelectSameWeekday() {
    let app = launch(at: "09:41")
    let today = Calendar.current.startOfDay(for: Date())
    let next = Calendar.current.date(byAdding: .day, value: 7, to: today)!
    let start = app.weekStripDay(today).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 0)))
    XCTAssertTrue(
      app.weekStripDay(today).waitForSelected(timeout: 3), "a short drag returns to the same day")
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
    XCTAssertTrue(app.weekStripDay(next).waitForSelected(timeout: 3))
    let nextStart = app.weekStripDay(next).coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    nextStart.press(forDuration: 0.05, thenDragTo: nextStart.withOffset(CGVector(dx: 100, dy: 0)))
    XCTAssertTrue(app.weekStripDay(today).waitForSelected(timeout: 3))
  }

  func testTodayDoesNotShowTomorrowDisclosure() {
    let app = launch(at: "19:30")
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    // Check each visible portion of the lazy list, including its footer. The fixture has
    // next-day items, so the former disclosure would have had a count in its label.
    let disclosure = list.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Tomorrow (")
    ).firstMatch
    for _ in 0..<8 {
      XCTAssertFalse(disclosure.exists, "Today has no Tomorrow disclosure")
      list.swipeUp()
    }
    XCTAssertFalse(disclosure.exists, "Today has no Tomorrow disclosure at the footer")
  }

  func testMorningSectionsStartCollapsed() {
    let app = launch(at: "09:41")
    XCTAssertFalse(app.buttons["focus.active"].exists)
    // Overdue sits above the timeline; the other disclosures follow it.
    let overdueLine = app.buttons["today.overdueShortcut"]
    let headers = [
      overdueLine, app.buttons["focus.settled"],
    ]
    for header in headers {
      reveal(header, in: app)
      XCTAssertEqual(header.value as? String, "Collapsed")
    }
    for (first, second) in zip(headers, headers.dropFirst()) {
      XCTAssertLessThan(first.frame.minY, second.frame.minY, "Trailing section order")
    }
    XCTAssertEqual(headers[0].label, "1 overdue")
    XCTAssertTrue(app.buttons["today.tidyOverdue"].exists, "Tidy sits beside the overdue line")
    XCTAssertFalse(app.staticTexts["Section overdue"].exists)
    screenshot("today-sections-collapsed")
    for button in [app.buttons["Today"], app.buttons["Ask AI or add anything"], app.buttons["New"]]
    {
      XCTAssertTrue(button.isHittable)
      XCTAssertGreaterThanOrEqual(button.frame.width, 44)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }
    let chat = app.buttons["Ask AI or add anything"].firstMatch
    let today = app.buttons["Today"].firstMatch
    let plus = app.buttons["New"]
    XCTAssertLessThan(chat.frame.maxX, today.frame.minX, "Chat field comes first")
    XCTAssertLessThan(today.frame.maxX, plus.frame.minX, "Today sits next to +")
    XCTAssertEqual(
      chat.frame.minX - app.frame.minX, app.frame.maxX - plus.frame.maxX, accuracy: 2,
      "Bottom bar keeps equal side margins")
    reveal(headers[0], in: app)
    headers[0].tap()
    XCTAssertEqual(headers[0].value as? String, "Expanded")
    let overdue = app.staticTexts["Section overdue"].firstMatch
    XCTAssertTrue(overdue.waitForExistence(timeout: 3))
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label == 'Section overdue'")).count, 1)
    reveal(overdue, in: app)
    XCTAssertTrue(
      app.buttons["Complete Section overdue"].exists, "Opening Overdue never completes it")
    screenshot("today-overdue-section-expanded")
    reveal(headers[0], in: app)
    headers[0].tap()
    XCTAssertFalse(overdue.exists)
    reveal(app.staticTexts["Section today"].firstMatch, in: app)
    XCTAssertTrue(
      app.buttons["Complete Section today"].exists, "Active items remain visible without a wrapper")
    // Match the original footer capture's device, dataset and app clock for the final visual comparison.
    app.terminate()
    app.launchArguments =
      TestData.launchArguments + ["-uiTestingNow", "13:13", "-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 8))
    Thread.sleep(forTimeInterval: 0.8)
    screenshot("today-sections-canonical-after")
  }

}

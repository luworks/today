import XCTest

/// Native geometry and interactions over the same versioned bilingual schedule.
@MainActor
final class TodayDensityTests: XCTestCase {
  private let longTitle = "回复设计评审邮件，确认中英文标题和无障碍检查结果"

  private func launch(largeText: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments =
      TestData.fixtureArguments("today-density.json") + [
        "-uiTestingNow", "10:30", "-today.setting.jumpToNow", "NO",
        "-today.setting.healthSummary", "YES",
        "-uiTestingPrefs", "showFreeTime=1",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "-appearance",
        largeText ? "dark" : "light",
        "-UIPreferredContentSizeCategoryName",
        largeText ? "UICTContentSizeCategoryAccessibilityL" : "UICTContentSizeCategoryL",
      ]
    app.launch()
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["health.summary"].waitForExistence(timeout: 5))
    return app
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + "-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let cells = app.collectionViews.firstMatch.cells.allElementsBoundByIndex
    let geometry = cells.map { cell -> [String: Any] in
      let frame = cell.frame
      return [
        "label": cell.label, "x": frame.minX, "y": frame.minY,
        "width": frame.width, "height": frame.height,
      ]
    }
    let data = try! JSONSerialization.data(
      withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
    let metrics = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    metrics.name = name + "-geometry"
    metrics.lifetime = .keepAlways
    add(metrics)
  }

  func testBilingualScheduleGeometryAndReminderEditor() {
    let app = launch()
    let title = app.staticTexts[longTitle]
    XCTAssertTrue(title.waitForExistence(timeout: 4))
    capture(app, name: "today-density-normal")
    let gaps = app.collectionViews.firstMatch.cells.containing(
      NSPredicate(format: "label BEGINSWITH %@", "Free ")
    ).allElementsBoundByIndex
    XCTAssertFalse(gaps.isEmpty)
    for gap in gaps {
      XCTAssertLessThanOrEqual(
        gap.frame.height, 18, "Free is a caption rather than an interactive row")
    }
    let complete = app.buttons["Complete Buy groceries and fill the car"]
    // Rounded: layout above the list can leave a sub-point fraction (43.99999…).
    XCTAssertGreaterThanOrEqual(complete.frame.width.rounded(), 44)
    XCTAssertGreaterThanOrEqual(complete.frame.height.rounded(), 44)
    XCTAssertTrue(app.staticTexts["16:45"].exists, "the row sits at its due time")
    XCTAssertTrue(app.staticTexts["Work"].firstMatch.exists)
    // Opening a reminder must still target the editor rather than its completion circle.
    title.tap()
    let cancel = app.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 4))
    cancel.tap()
    XCTAssertTrue(title.waitForExistence(timeout: 4))
    title.swipeLeft()
    XCTAssertTrue(app.buttons["Settle"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Tomorrow"].firstMatch.exists)
    XCTAssertTrue(app.buttons["Delete"].firstMatch.exists)
    capture(app, name: "today-density-swipe")
    // The swiped title is shifted toward the left edge, where a right drag opens the sidebar.
    app.collectionViews.firstMatch.cells.containing(
      NSPredicate(format: "label BEGINSWITH %@", "Free ")
    ).firstMatch.tap()
    XCTAssertTrue(app.buttons["Settle"].firstMatch.waitForNonExistence(timeout: 3))
    complete.tap()
    XCTAssertTrue(app.staticTexts["Buy groceries and fill the car"].waitForNonExistence(timeout: 3))
    XCTAssertFalse(
      app.buttons["Cancel"].firstMatch.exists, "The completion target never opens the editor")
  }

  func testAccessibilityTextKeepsLongTitleRowReachable() {
    let app = launch(largeText: true)
    capture(app, name: "today-density-large-top")
    let title = app.staticTexts[longTitle]
    let list = app.collectionViews.firstMatch
    var viewport = list.frame.intersection(app.frame)
    let chat = app.buttons["Ask AI or add anything"]
    if chat.exists { viewport.size.height = min(viewport.maxY, chat.frame.minY) - viewport.minY }
    for _ in 0..<6 {
      if title.exists, title.isHittable, title.isFullyVisible(in: viewport) { break }
      if !title.exists || title.frame.maxY > viewport.maxY {
        list.swipeUp()
      } else {
        list.swipeDown()
      }
    }
    XCTAssertTrue(title.isHittable)
    XCTAssertTrue(title.isFullyVisible(in: viewport), "The title row stays fully reachable")
    XCTAssertGreaterThan(title.frame.height, 20, "The title uses accessibility-sized text")
    capture(app, name: "today-density-large-title")
    title.tap()
    XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 4))
  }
}

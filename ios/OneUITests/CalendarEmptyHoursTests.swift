import XCTest

/// Exercises the 2 Day gap control with a sparse, local-only schedule.
@MainActor
final class CalendarEmptyHoursTests: XCTestCase {
  func testEmptyHoursExpandAndCollapse() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments =
      TestData.fixtureArguments("calendar-empty-hours.json") + [
        "-uiTestingNow", "09:00", "-uiTestingPrefs", "compressEmptyHours=1",
        "-AppleLocale", "en_US",
      ]
    app.launch()
    app.buttons["Calendar"].firstMatch.tap()

    let grid = app.descendants(matching: .any)["calendar.dayGrid"]
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["calendar.mode.twoday"].isSelected)

    // The range is owned by the layout; select a visible gap rather than guessing
    // its boundary units or assuming a particular initial scroll position.
    let gaps = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.gap.'"))
    var gap: XCUIElement?
    for _ in 0..<8 {
      gap = gaps.allElementsBoundByIndex.first { $0.isHittable }
      if gap != nil { break }
      grid.swipeUp()
    }
    let collapsed = try XCTUnwrap(gap, "A compressed empty-hour control should be reachable")
    let id = collapsed.identifier
    XCTAssertEqual(id.components(separatedBy: ".").count, 4, "Expected calendar.gap.<start>.<end>")
    XCTAssertEqual(collapsed.value as? String, "Collapsed")

    collapsed.tap()
    let expanded = app.buttons[id]
    let expandedValue = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Expanded"), object: expanded)
    XCTAssertEqual(XCTWaiter().wait(for: [expandedValue], timeout: 5), .completed)
    XCTAssertTrue(expanded.isHittable, "The expanded gap must remain available to collapse")

    expanded.tap()
    let collapsedValue = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Collapsed"), object: app.buttons[id])
    XCTAssertEqual(XCTWaiter().wait(for: [collapsedValue], timeout: 5), .completed)
  }
  func testGapBandLabelDoesNotOverlapHourLabels() throws {
    let app = XCUIApplication()
    app.launchArguments =
      TestData.fixtureArguments("calendar-compressed-gaps.json") + [
        "-uiTestingNow", "09:00", "-uiTestingPrefs", "compressEmptyHours=1", "-AppleLocale",
        "en_US",
      ]
    app.launch()
    app.buttons["Calendar"].firstMatch.tap()
    let band = app.buttons["calendar.gapBand.0.8"]
    XCTAssertTrue(band.waitForExistence(timeout: 10))
    XCTAssertEqual(band.label, "00–08")
    XCTAssertGreaterThanOrEqual(band.frame.height, 44)
    let labels = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH 'calendar.hour.'"))
    XCTAssertGreaterThan(labels.count, 0)
    for hour in labels.allElementsBoundByIndex where hour.exists {
      XCTAssertFalse(band.frame.intersects(hour.frame), "Gap label overlaps \(hour.identifier)")
    }
    band.tap()
    XCTAssertEqual(app.buttons["calendar.gap.0.8"].value as? String, "Expanded")
  }

}

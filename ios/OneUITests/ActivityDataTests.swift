import XCTest

/// Settings → Activity data (what is recorded, pause, export, clear) and the Activity screen's paging on the Activity store.
@MainActor
final class ActivityDataTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
    }
  }

  private func launch(_ extra: [String] = []) {
    app.launchArguments = TestData.launchArguments + ["-uiTestingNow", "09:41"] + extra
    app.launch()
  }

  private func openActivityData() {
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let row = app.buttons["settings.activityData"]
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
    row.tap()
    XCTAssertTrue(app.navigationBars["Activity data"].waitForExistence(timeout: 5))
  }

  private func openActivityFromSidebar() {
    let row = app.buttons["Activity"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "the sidebar has an Activity row")
    row.tap()
    XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
  }

  /// A hittable row may still be clipped against the sheet's bottom/home indicator.
  private func scrollTo(_ element: XCUIElement, swipes: Int = 40) {
    for attempt in 0...swipes {
      if element.exists && element.isHittable {
        let frame = element.frame
        let top = app.navigationBars.firstMatch.frame.maxY
        let viewport = CGRect(
          x: app.frame.minX, y: top, width: app.frame.width,
          height: max(0, app.frame.maxY - 44 - top))
        if frame.width > 0, frame.height > 0, viewport.contains(frame) { return }
      }
      if attempt < swipes { app.swipeUp(velocity: .fast) }
    }
    XCTFail("The complete row must be visible above the sheet bottom: \(element)")
  }

  /// The page says where the data lives, pausing shows on the Activity screen, and Clear empties it.
  func testPageExplainsPausesAndClears() {
    launch(["-uiTestingActivityRows", "5"])
    openActivityData()
    let pause = app.switches["activity.pause"]
    XCTAssertEqual(pause.value as? String, "0")
    XCTAssertTrue(app.switches["activity.tier.1"].exists, "one switch per category")
    // Pause shows on the Activity screen, with the one-line note about where the data lives.
    pause.toggleSwitch()
    let keep = app.switches["activity.keepChatText"]
    scrollTo(keep, swipes: 6)
    XCTAssertEqual(keep.value as? String, "1", "chat text is kept by default, on this iPhone only")
    XCTAssertTrue(app.switches["activity.tier.4"].exists)
    let where_ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'On this iPhone'"))
      .firstMatch
    scrollTo(where_, swipes: 6)
    XCTAssertTrue(where_.exists, "says where it lives")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Done"].tap()
    openActivityFromSidebar()
    let note = app.staticTexts["activity.note"]
    XCTAssertTrue(note.waitForExistence(timeout: 3))
    XCTAssertTrue(note.label.contains("Recording is paused"), note.label)
    XCTAssertTrue(note.label.contains("only on this iPhone"), note.label)
    XCTAssertTrue(
      app.staticTexts["Completed “Synthetic 0”"].exists, "recorded changes are still listed")
    app.buttons["Done"].tap()

    // Clear: confirmation names the count; afterwards Activity is empty.
    app.buttons["Settings"].firstMatch.tap()
    let row = app.buttons["settings.activityData"]
    scrollTo(row)
    row.tap()
    let clear = app.buttons["activity.clear"]
    scrollTo(clear)
    let clearFrame = app.buttons["activity.clear"].frame
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(dx: clearFrame.midX - app.frame.minX, dy: clearFrame.midY - app.frame.minY)
      ).tap()
    let confirm = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Clear ' AND label ENDSWITH ' Events'")
    ).firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the confirmation names how many events go")
    confirm.tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Done"].tap()
    openActivityFromSidebar()
    XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 3))
  }

  /// 400 changes: pages of 150 (150, 300, then the last 100) with "Show more" between; nothing loads all at once.
  func testActivityPagesWithShowMore() {
    launch(["-uiTestingActivityRows", "400"])
    app.openSidebar()
    openActivityFromSidebar()
    XCTAssertTrue(
      app.staticTexts["Completed “Synthetic 0”"].waitForExistence(timeout: 5), "newest first")
    XCTAssertFalse(
      app.staticTexts["Completed “Synthetic 399”"].exists, "the oldest is not loaded yet")
    let more = app.buttons["Show more"]
    for page in 1...2 {
      scrollTo(more)
      XCTAssertTrue(more.exists, "page \(page) ends with Show more")
      more.tap()
    }
    XCTAssertTrue(
      more.waitForNonExistence(timeout: 3),
      "400 rows = 150 + 150 + 100: no more after the second tap")
    for _ in 0..<12 { app.swipeUp() }
    XCTAssertTrue(
      app.staticTexts["Completed “Synthetic 399”"].waitForExistence(timeout: 3),
      "the oldest row is there")
  }

  /// Search asks the store within the current chip: a seeded title is found, nothing matches shows the empty state, and
  /// clearing the search returns to the full list where it was scrolled.
  func testSearchFindsATitleAndClearingRestoresTheList() {
    launch(["-uiTestingActivityRows", "40"])
    app.openSidebar()
    openActivityFromSidebar()
    let newest = app.staticTexts["Completed “Synthetic 0”"]
    XCTAssertTrue(newest.waitForExistence(timeout: 5))
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertFalse(newest.exists && newest.isHittable, "scrolled away from the top")

    let field = app.searchFields["Search Activity"]
    XCTAssertTrue(field.waitForExistence(timeout: 3), "a native search field")
    field.tap()
    field.typeText("Synthetic 37")
    let match = app.staticTexts["Completed “Synthetic 37”"]
    XCTAssertTrue(match.waitForExistence(timeout: 3), "the seeded title is found")
    XCTAssertTrue(match.isHittable)
    XCTAssertFalse(newest.exists, "only matches are listed")

    field.buttons["Clear text"].firstMatch.tap()
    let rows = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH 'Completed “Synthetic'"))
    XCTAssertTrue(
      rows.element(boundBy: 1).waitForExistence(timeout: 3),
      "clearing restores the list: \(rows.count) rows")
    XCTAssertFalse(
      newest.exists && newest.isHittable, "at the same scroll position, not back at the top")

    // Combined with the chip: the seeded changes are yours, so AI finds none.
    field.typeText("Synthetic 37")
    XCTAssertTrue(match.waitForExistence(timeout: 3))
    app.buttons["activity.filter.AI"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch
        .waitForExistence(timeout: 3), "an empty state when nothing matches")
    XCTAssertFalse(match.exists)
  }

  /// Export opens the system share sheet with a file.
  func testExportOpensTheShareSheet() {
    launch(["-uiTestingActivityRows", "3"])
    openActivityData()
    let jsonl = app.buttons["activity.export.jsonl"]
    scrollTo(jsonl)
    XCTAssertTrue(jsonl.isEnabled, "there is something to export")
    jsonl.tap()
    let sheet = app.otherElements["ActivityListView"]
    let copy = app.buttons["Copy"]
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 8) || copy.waitForExistence(timeout: 2),
      "the share sheet appears")
  }
}

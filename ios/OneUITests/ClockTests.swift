import XCTest

/// Clock's sections inside the Clock tab: the switcher, World Clock (add / delete a city) and the Stopwatch.
/// Set TEST_RUNNER_CLOCK_SHOTS=<folder> to save light and dark screenshots of each section (`testScreenshots`).
@MainActor
final class ClockTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(_ extra: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = ["-uiTesting"] + extra
    app.launch()
    let alarms = app.buttons["Clock"].firstMatch
    XCTAssertTrue(alarms.waitForExistence(timeout: 5))
    alarms.tap()
  }

  private func section(_ name: String) -> XCUIElement {
    app.buttons["clock.section." + name].firstMatch
  }
  private var cityRows: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "worldClock.row")
  }
  private var laps: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "stopwatch.lap")
  }
  private var plus: XCUIElement { app.buttons["New"] }

  private var pill: XCUIElement { app.buttons["worldClock.scrub"] }

  /// Opens the picker and searches. `typeText` with Chinese characters needs the simulator to accept them;
  /// the English searches are the reliable ones.
  private func search(_ text: String) {
    app.addNew("Add city")
    XCTAssertTrue(app.staticTexts["Choose a City"].waitForExistence(timeout: 5))
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
    field.typeText(text)
  }

  private func cityButton(_ name: String, _ cc: String) -> XCUIElement {
    app.buttons["city.\(name).\(cc)"].firstMatch
  }

  func testSwitchingSectionsAndPlus() {
    launch()
    XCTAssertTrue(section("alarms").waitForExistence(timeout: 5))
    XCTAssertTrue(section("alarms").isSelected, "Alarms is the default section")
    XCTAssertTrue(plus.exists, "+ adds an alarm")
    XCTAssertFalse(
      app.staticTexts["timer.title"].exists,
      "Timers has its own section, separate from the alarm list")

    section("worldClock").tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["worldClock.home"].waitForExistence(timeout: 3),
      "home is always the first card")
    XCTAssertTrue(plus.exists, "+ adds a city on World Clock")

    section("stopwatch").tap()
    XCTAssertTrue(app.staticTexts["stopwatch.time"].waitForExistence(timeout: 3))
    XCTAssertTrue(plus.exists, "creation stays available on Stopwatch")
    XCTAssertEqual(plus.label, "Add an item")

    section("timer").tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["timer.picker"].waitForExistence(timeout: 3),
      "the Timers screen is the Timer section")
    XCTAssertFalse(app.staticTexts["Timers"].exists, "no large title: the pill already says Timer")
    XCTAssertEqual(app.pickerWheels.count, 3, "hours, minutes and seconds")
    app.revealTimerControl(app.buttons["timer.start"].firstMatch)
    XCTAssertFalse(app.buttons["timer.start"].isEnabled, "the empty picker cannot start a timer")
    XCTAssertTrue(plus.exists, "creation stays available without starting a timer")
    XCTAssertEqual(plus.label, "Add an item")
    plus.tap()
    XCTAssertTrue(app.buttons["New reminder"].waitForExistence(timeout: 3))
    app.buttons["New reminder"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["quick.title"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.staticTexts["timer.title"].waitForExistence(timeout: 3))
    XCTAssertFalse(
      app.buttons["timer.start"].isEnabled, "+ did not change or start the empty timer")

    // The section is kept when you leave the tab and come back.
    app.buttons["Today"].firstMatch.tap()
    XCTAssertTrue(plus.waitForExistence(timeout: 3), "+ is back on other tabs")
    app.buttons["Clock"].firstMatch.tap()
    XCTAssertTrue(section("timer").waitForExistence(timeout: 3))
    XCTAssertTrue(section("timer").isSelected, "back on Timer")
    XCTAssertTrue(plus.exists)
    XCTAssertEqual(plus.label, "Add an item")
  }

  func testAddAndDeleteCity() {
    launch(["-uiTestingHomeZone", "America/Los_Angeles"])
    section("worldClock").tap()
    XCTAssertTrue(app.descendants(matching: .any)["worldClock.hint"].waitForExistence(timeout: 3))
    XCTAssertEqual(cityRows.count, 0)

    search("Tokyo")
    let tokyo = cityButton("Tokyo", "JP")
    XCTAssertTrue(tokyo.waitForExistence(timeout: 3), "search finds Tokyo")
    XCTAssertTrue(tokyo.label.hasPrefix("Tokyo, "), "the row says the country: \(tokyo.label)")
    XCTAssertTrue(tokyo.label.contains("UTC+9"), "and the UTC offset: \(tokyo.label)")
    tokyo.tap()

    XCTAssertTrue(cityRows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(cityRows.count, 1)
    let label = cityRows.firstMatch.label
    XCTAssertTrue(label.hasPrefix("Tokyo, +1"), "shows the offset to home (+16 or +17): \(label)")
    XCTAssertTrue(app.descendants(matching: .any)["worldClock.home"].exists, "home stays first")
    XCTAssertTrue(
      label.contains("Saturday") || label.contains("Sunday") || label.contains("Monday")
        || label.contains("Friday"), "and the date: \(label)")

    // A sideways drag scrubs time, so deleting is in the long-press menu; there is no Edit button.
    XCTAssertFalse(app.buttons["worldClock.edit"].exists, "no Edit button")
    cityRows.firstMatch.press(forDuration: 1.0)
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "the long-press menu has Delete")
    delete.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["worldClock.hint"].waitForExistence(timeout: 3),
      "the city is gone")
    XCTAssertEqual(cityRows.count, 0)
    let undo = app.buttons["Undo"].firstMatch
    XCTAssertTrue(undo.waitForExistence(timeout: 3))
    undo.tap()
    XCTAssertTrue(cityRows.firstMatch.waitForExistence(timeout: 3), "Undo brings it back")
  }

  func testDeleteFromLongPressMenu() {
    launch(["-uiTestingCities", "Europe/London"])
    section("worldClock").tap()
    let row = cityRows.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.press(forDuration: 1.0)
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    delete.tap()
    XCTAssertTrue(app.descendants(matching: .any)["worldClock.hint"].waitForExistence(timeout: 3))
  }

  /// Drag sideways on the cities: every clock moves in minutes, the pill says how far, a tap on it goes back to NOW.
  /// The pill is there from the start (reading NOW); there is no Overlap capsule.
  func testScrubbing() {
    launch([
      "-uiTestingCities", "Europe/London,Asia/Tokyo",
      "-uiTestingHomeZone", "America/Los_Angeles", "-uiTestingNow", "12:50",
    ])
    section("worldClock").tap()
    let tokyo = cityRows.element(boundBy: 1)
    XCTAssertTrue(tokyo.waitForExistence(timeout: 3))
    let home = app.descendants(matching: .any)["worldClock.home"].firstMatch
    let london = cityRows.element(boundBy: 0)
    let clocks = [home, london, tokyo]
    XCTAssertTrue(pill.exists, "the pill is always there")
    XCTAssertEqual(pill.label, "NOW")
    XCTAssertFalse(app.buttons["worldClock.overlap"].exists, "no Overlap capsule")
    let before = clocks.map({ $0.label })

    // Start inside the card, clear of the sidebar's reserved 44pt edge: every city moves into the past.
    tokyo.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: tokyo.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
        withVelocity: .slow, thenHoldForDuration: 0.1)
    XCTAssertTrue(
      pill.label.hasSuffix("MIN BEFORE NOW"), "the card-width drag moves minutes: \(pill.label)")
    XCTAssertFalse(pill.label.contains("HOUR"), "a card-width drag stays under an hour")
    for (clock, original) in zip(clocks, before) {
      XCTAssertNotEqual(clock.label, original, "every clock moved")
    }
    XCTAssertEqual(cityRows.count, 2, "a drag scrubs; it never deletes")

    XCTAssertTrue(pill.isFullyVisible(in: app.frame))
    pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(pill.label, "NOW", "tapping the pill goes back to NOW")
    XCTAssertEqual(clocks.map({ $0.label }), before)

    // Drag left from Now: every city advances into the future.
    tokyo.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: tokyo.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
        withVelocity: .slow, thenHoldForDuration: 0.1)
    XCTAssertTrue(pill.label.hasSuffix("MIN AFTER NOW"), pill.label)
    XCTAssertFalse(pill.label.contains("HOUR"), "a card-width drag stays under an hour")
    for (clock, original) in zip(clocks, before) {
      XCTAssertNotEqual(clock.label, original, "every clock moved")
    }
    XCTAssertTrue(pill.isFullyVisible(in: app.frame))
    pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(pill.label, "NOW")
    XCTAssertEqual(clocks.map({ $0.label }), before)
  }

  /// The graph is one icon next to the pill (no capsule): the cards flatten, the sentence appears, the icon swaps back.
  func testOverlapGraph() {
    launch(["-uiTestingCities", "Europe/London,America/New_York"])
    section("worldClock").tap()
    let graph = app.buttons["worldClock.graph"]
    XCTAssertTrue(graph.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["worldClock.overlapText"].exists, "the cards come first")
    graph.tap()
    let text = app.staticTexts["worldClock.overlapText"]
    XCTAssertTrue(text.waitForExistence(timeout: 3))
    XCTAssertTrue(text.label.hasPrefix("Overlap for London and New York"), text.label)
    XCTAssertTrue(pill.exists, "scrubbing still works in the graph")
    XCTAssertEqual(cityRows.count, 2, "the cities stay, as flat rows")
    graph.tap()
    XCTAssertTrue(text.waitForNonExistence(timeout: 3))
  }

  /// 'Beijing' and the Chinese name find the same city; 'china' lists Chinese cities; adding Beijing shows its card.
  func testSearchBeijingAndChina() {
    launch(["-uiTestingHomeZone", "America/Los_Angeles"])
    section("worldClock").tap()
    search("china")
    XCTAssertTrue(cityButton("Beijing", "CN").waitForExistence(timeout: 3), "'china' lists Beijing")
    XCTAssertTrue(cityButton("Shanghai", "CN").exists, "and Shanghai")
    XCTAssertTrue(
      cityButton("Shenzhen", "CN").exists || cityButton("Guangzhou", "CN").exists,
      "and the other big ones")
    let field = app.searchFields.firstMatch
    field.buttons["Clear text"].firstMatch.tap()
    field.typeText("Beijing")
    let beijing = cityButton("Beijing", "CN")
    XCTAssertTrue(beijing.waitForExistence(timeout: 3), "search finds Beijing")
    XCTAssertTrue(beijing.label.hasPrefix("Beijing, China"), beijing.label)
    XCTAssertTrue(beijing.label.contains("UTC+8"), beijing.label)
    beijing.tap()
    XCTAssertTrue(cityRows.firstMatch.waitForExistence(timeout: 5))
    let label = cityRows.firstMatch.label
    XCTAssertTrue(
      label.hasPrefix("Beijing, +1"), "a card with the offset to home and its time: \(label)")
  }

  func testSearchByChineseName() {
    launch()
    section("worldClock").tap()
    search("北京")
    let beijing = cityButton("Beijing", "CN")
    XCTAssertTrue(beijing.waitForExistence(timeout: 5), "the Chinese name finds Beijing")
    XCTAssertTrue(
      app.buttons["city.Shanghai.CN"].firstMatch.exists == false, "and only the matching cities")
  }

  /// No Edit mode: a city's long-press menu moves it up or down.
  func testReorderFromLongPressMenu() {
    launch(["-uiTestingCities", "Europe/London,Asia/Tokyo"])
    section("worldClock").tap()
    XCTAssertTrue(cityRows.element(boundBy: 1).waitForExistence(timeout: 3))
    XCTAssertTrue(cityRows.element(boundBy: 0).label.hasPrefix("London"))
    XCTAssertFalse(app.buttons["worldClock.edit"].exists, "no Edit button")
    cityRows.element(boundBy: 1).press(forDuration: 1.0)
    let up = app.buttons["Move Up"]
    XCTAssertTrue(up.waitForExistence(timeout: 3), "the long-press menu has Move Up")
    up.tap()
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.cityRows.element(boundBy: 0).label.hasPrefix("Tokyo") },
      object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "Tokyo moved up")
  }

  func testStopwatchStartLapStopReset() {
    launch()
    section("stopwatch").tap()
    let time = app.staticTexts["stopwatch.time"]
    let startStop = app.buttons["stopwatch.startStop"]
    let lapReset = app.buttons["stopwatch.lapReset"]
    XCTAssertTrue(time.waitForExistence(timeout: 3))
    XCTAssertEqual(time.label, "Stopwatch, 0 seconds")
    XCTAssertEqual(lapReset.label, "Lap")
    XCTAssertFalse(lapReset.isEnabled, "Lap is off before the first start")

    startStop.tap()
    XCTAssertEqual(startStop.label, "Stop")
    sleep(1)
    lapReset.tap()
    sleep(1)
    lapReset.tap()
    // Lap 3 (running) + two finished laps.
    XCTAssertEqual(laps.count, 3)
    XCTAssertNotEqual(time.label, "Stopwatch, 0 seconds, running", "it is running")

    // Keeps running on another tab.
    app.buttons["Today"].firstMatch.tap()
    app.buttons["Clock"].firstMatch.tap()
    XCTAssertTrue(startStop.waitForExistence(timeout: 3))
    XCTAssertEqual(startStop.label, "Stop", "still running after switching tabs")

    startStop.tap()
    XCTAssertEqual(startStop.label, "Start")
    XCTAssertEqual(lapReset.label, "Reset")
    let stopped = time.label
    sleep(1)
    XCTAssertEqual(time.label, stopped, "stopped means stopped")
    lapReset.tap()
    XCTAssertEqual(time.label, "Stopwatch, 0 seconds")
    XCTAssertEqual(laps.count, 0)
    XCTAssertEqual(lapReset.label, "Lap")
  }

  /// Light and dark screenshots of each section, for design review.
  func testScreenshots() throws {
    guard let dir = ProcessInfo.processInfo.environment["CLOCK_SHOTS"] else {
      throw XCTSkip("set TEST_RUNNER_CLOCK_SHOTS")
    }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Run once with the simulator in light mode and once in dark (`xcrun simctl ui <udid> appearance dark`),
    // with TEST_RUNNER_CLOCK_SHOTS_SUFFIX=light / dark.
    let suffix = ProcessInfo.processInfo.environment["CLOCK_SHOTS_SUFFIX"] ?? "light"
    do {
      launch([
        "-dataset", TestData.path, "-uiTestingCities",
        "America/New_York,Europe/London,Asia/Kolkata,Asia/Tokyo",
      ])
      func shot(_ name: String) {
        _ = app.wait(for: .runningForeground, timeout: 1)
        try? XCUIScreen.main.screenshot().pngRepresentation
          .write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(suffix).png"))
      }
      XCTAssertTrue(section("alarms").waitForExistence(timeout: 5))
      shot("1-alarms")
      section("worldClock").tap()
      XCTAssertTrue(cityRows.firstMatch.waitForExistence(timeout: 3))
      shot("2-world-clock")
      let row = cityRows.element(boundBy: 1)
      row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)),
          withVelocity: .slow, thenHoldForDuration: 0.1)
      shot("2b-world-clock-scrubbed")
      pill.tap()
      app.addNew("Add city")
      XCTAssertTrue(app.staticTexts["Choose a City"].waitForExistence(timeout: 5))
      shot("3-choose-city")
      app.buttons["Cancel"].tap()
      section("stopwatch").tap()
      app.buttons["stopwatch.startStop"].tap()
      for _ in 0..<3 {
        usleep(700_000)
        app.buttons["stopwatch.lapReset"].tap()
      }
      usleep(400_000)
      app.buttons["stopwatch.startStop"].tap()
      shot("4-stopwatch")
      section("timer").tap()
      XCTAssertTrue(app.staticTexts["timer.title"].waitForExistence(timeout: 3))
      XCTAssertEqual(app.pickerWheels.count, 3)
      shot("5-timer")
      app.terminate()

      // The reference frames: home San Jose, Dallas, Boston, Aba, Beijing at 18:20 (the clock is pinned).
      let reference = [
        "-uiTestingNow", "18:20", "-uiTestingHomeCity", "g5392171",
        "-uiTestingCities", "g4684888,g4930956,g2353151,g1816670",
      ]
      launch(reference)
      section("worldClock").tap()
      XCTAssertTrue(cityRows.firstMatch.waitForExistence(timeout: 3))
      usleep(500_000)
      shot("6-reference-now")
      let first = cityRows.element(boundBy: 0)
      // Three leftward drags advance by one minute per 10 pt; retain a scrubbed reference frame.
      for _ in 0..<3 {
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
          .press(
            forDuration: 0.05,
            thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
            withVelocity: .fast, thenHoldForDuration: 0.1)
      }
      usleep(500_000)
      shot("6b-reference-scrubbed")
      pill.tap()
      app.buttons["worldClock.graph"].tap()
      usleep(800_000)
      shot("6c-reference-graph")
      app.terminate()
    }
  }
}

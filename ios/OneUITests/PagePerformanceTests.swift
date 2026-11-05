import XCTest

/// App-monotonic action -> destination geometry + two display-link callbacks.
/// These samples do not assert async data readiness, animation completion or touch-to-photon time.
/// Each method launches once, then runs first_cycle_plus_two_revisits in an isolated in-memory dataset.
/// Preserve raw seq/route_visit order; candidate runs must match this exact journey sequence.
/// The first visit and revisits are descriptive samples, not a homogeneous warm/cold baseline.
@MainActor
final class PagePerformanceTests: XCTestCase {
  private var app: XCUIApplication!
  private var lastReport = ""

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments =
        TestData.launchArguments + [
          "-performanceTrace", "-performancePageRevisits", "-uiTestingNow", "09:41",
          "-today.setting.healthSummary", "YES",
        ]
    }
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  private func launch() {
    app.terminate()
    lastReport = ""
    app.launch()
    readSample(name: "app_init_to_content_layout", route: "today")
    XCTAssertTrue(app.buttons["New"].isHittable)
  }

  private func readSample(name: String, route: String) {
    // A modal exposes its own report because UIKit can hide the presenter's accessibility tree.
    let reports = app.staticTexts.matching(identifier: "performance.trace")
    let prior = lastReport
    let predicate = NSPredicate { _, _ in
      reports.allElementsBoundByIndex.contains {
        $0.label != prior && $0.label.contains(";name=\(name);")
          && $0.label.contains(";route=\(route);")
      }
    }
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10),
      .completed, "App destination endpoint: \(route)")
    guard
      let report = reports.allElementsBoundByIndex.map({ $0.label }).first(where: {
        $0 != prior && $0.contains(";name=\(name);") && $0.contains(";route=\(route);")
      })
    else {
      XCTFail("No fresh destination report")
      return
    }
    let fields = Dictionary(
      uniqueKeysWithValues: report.split(separator: ";").compactMap { field -> (String, String)? in
        let pair = field.split(separator: "=", maxSplits: 1)
        return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
      })
    XCTAssertEqual(fields["v"], "1")
    XCTAssertEqual(fields["name"], name)
    XCTAssertEqual(fields["route"], route)
    if name.hasPrefix("page.") {
      XCTAssertEqual(fields["page_context"], "first_cycle_plus_two_revisits")
      XCTAssertNotNil(Int(fields["route_visit"] ?? ""))
    }
    guard let seq = Int(fields["seq"] ?? ""), let start = UInt64(fields["start_ns"] ?? ""),
      let end = UInt64(fields["end_ns"] ?? ""), let ms = Double(fields["ms"] ?? "")
    else {
      XCTFail("Missing exact monotonic fields: \(report)")
      return
    }
    XCTAssertGreaterThan(seq, 0)
    XCTAssertGreaterThanOrEqual(end, start)
    XCTAssertTrue(ms.isFinite && ms >= 0)
    XCTAssertEqual(ms, Double(end - start) / 1_000_000, accuracy: 0.001)
    lastReport = report
    print("PERF_SAMPLE_APP \(report)")
    let attachment = XCTAttachment(string: report)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if app.launchArguments.contains("-performanceResources") {
      readResources(sequence: seq, start: start, layout: end, route: route)
    }
  }

  private func readResources(sequence: Int, start: UInt64, layout: UInt64, route: String) {
    if let report = capturePageResourceWindow(
      app: app, sequence: sequence, start: start, layout: layout, route: route)
    {
      lastReport = report
    }
  }

  /// Separate resource cohort; original latency journeys and assertions are reused unchanged.
  func testHealthResourceWindows() {
    app.launchArguments.append("-performanceResources")
    testHealthListDetailAndPickerEndpoints()
  }

  func testClockResourceWindows() {
    app.launchArguments.append("-performanceResources")
    testClockModesAndCityPickerEndpoints()
  }

  func testSettingsActivityResourceWindows() {
    app.launchArguments.append("-performanceResources")
    testSettingsSubpageAndActivityEndpoints()
  }

  func testSearchReminderResourceWindows() {
    app.launchArguments.append("-performanceResources")
    testSearchQuickReminderAndReminderDetailEndpoints()
  }

  private func tap(_ target: XCUIElement, route: String, ready: XCUIElement) {
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    let hittable = target.isHittable
    if !hittable {
      // Diagnose the original failed observation without retrying or changing the action.
      let identifier = target.identifier
      let label = target.label
      let sameType = app.descendants(matching: target.elementType)
      let identifierCount: Any =
        identifier.isEmpty
        ? NSNull()
        : sameType.matching(NSPredicate(format: "identifier == %@", identifier)).count
      let labelCount: Any =
        label.isEmpty
        ? NSNull()
        : sameType.matching(NSPredicate(format: "label == %@", label)).count
      let context: [String: Any] = [
        "route": route, "identifier": identifier, "label": label,
        "element_type": target.elementType.rawValue, "frame": String(describing: target.frame),
        "exists": target.exists, "enabled": target.isEnabled, "hittable": hittable,
        "same_type_identifier_count": identifierCount, "same_type_label_count": labelCount,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        print("PERF_REACHABILITY_FAILURE \(json)")
      }
      print(
        "PERF_REACHABILITY_HIERARCHY_BEGIN route=\(route)\n\(app.debugDescription)\nPERF_REACHABILITY_HIERARCHY_END route=\(route)"
      )
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "unreachable.\(route)"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
    XCTAssertTrue(hittable, "Action is reachable: \(route)")
    target.tap()
    readSample(name: "page.\(route)", route: route)
    XCTAssertTrue(ready.waitForExistence(timeout: 5), "Destination content: \(route)")
  }

  /// Estimated 60-90 seconds. Health sample fixture only; no HealthKit permission or load latency claim.
  func testHealthListDetailAndPickerEndpoints() {
    launch()
    for _ in 0..<3 {
      let summary = app.buttons["health.summary"]
      for _ in 0..<4 where !(summary.exists && summary.isHittable) { app.swipeDown() }
      tap(summary, route: "health", ready: app.buttons["health.row.steps"])
      tap(
        app.buttons["health.row.steps"], route: "health.detail",
        ready: app.buttons["health.range.30"])
      XCTAssertTrue(element("health.detail.value").exists)
      app.buttons["health.detail.done"].tap()
      let manage = app.buttons["health.add"]
      for _ in 0..<3 where !manage.isHittable { app.swipeUp() }
      tap(manage, route: "health.picker", ready: app.switches["health.pick.steps"])
      // Opening and closing the picker preserves selection; never request new Health access.
      app.buttons["health.pick.add"].tap()
      app.buttons["Done"].firstMatch.tap()
    }
  }

  /// Estimated 90-150 seconds. Reads Settings and Activity data without toggles, export, Clear or Delete.
  func testSettingsSubpageAndActivityEndpoints() {
    launch()
    let menu = app.buttons["Open menu"]
    let closedMenuX = menu.frame.minX
    for _ in 0..<3 {
      menu.tap()
      tap(app.buttons["Settings"], route: "settings", ready: app.navigationBars["Settings"])
      let data = app.buttons["settings.activityData"]
      app.revealSettingsRow(data)
      tap(data, route: "settings.activityData", ready: app.navigationBars["Activity data"])
      app.navigationBars.buttons["Settings"].tap()
      app.buttons["Done"].firstMatch.tap()
      // The sidebar intentionally remains underneath the modal.
      tap(app.buttons["Activity"], route: "activity", ready: app.navigationBars["Activity"])
      XCTAssertTrue(app.buttons["activity.filter.All"].exists)
      app.buttons["Done"].firstMatch.tap()
      app.buttons["Close sidebar"].tap()
      // Wait for the closing page to return before the next menu tap can reach it.
      let closed = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          !self.app.buttons["Close sidebar"].exists && menu.isHittable
            && abs(menu.frame.minX - closedMenuX) < 0.5
        }, object: nil)
      XCTAssertEqual(
        XCTWaiter().wait(for: [closed], timeout: 5), .completed,
        "Sidebar closes before the next opening action")
    }
  }

  /// Estimated 60-100 seconds. No alarm authorization, timer start, city write or stopwatch run.
  func testClockModesAndCityPickerEndpoints() {
    launch()
    app.buttons["Clock"].firstMatch.tap()
    for _ in 0..<3 {
      tap(
        app.buttons["clock.section.worldClock"], route: "clock.worldClock",
        ready: element("worldClock.home"))
      app.buttons["New"].tap()
      tap(
        app.buttons["Add city"], route: "clock.cityPicker",
        ready: app.navigationBars["Choose a City"])
      XCTAssertTrue(app.searchFields.firstMatch.exists)
      app.buttons["Cancel"].firstMatch.tap()
      tap(
        app.buttons["clock.section.stopwatch"], route: "clock.stopwatch",
        ready: app.buttons["Start"])
      tap(app.buttons["clock.section.timer"], route: "clock.timer", ready: element("timer.picker"))
      tap(
        app.buttons["clock.section.alarms"], route: "clock.alarms",
        ready: app.buttons["clock.section.alarms"])
    }
  }

  /// Estimated 90-140 seconds. Single input mutation measures query->results layout, with no text in the trace.
  func testSearchQuickReminderAndReminderDetailEndpoints() {
    launch()
    for _ in 0..<3 {
      app.buttons["Open menu"].tap()
      tap(app.buttons["Search"], route: "search", ready: app.textFields["search.field"])
      app.textFields["search.field"].tap()
      app.textFields["search.field"].typeText("m")
      readSample(name: "page.search.results", route: "search.results")
      let milk = app.buttons.matching(
        NSPredicate(format: "identifier == 'search.result' AND label BEGINSWITH 'Buy milk'")
      ).firstMatch
      XCTAssertTrue(milk.waitForExistence(timeout: 5))
      app.buttons["Close search"].tap()
      app.buttons["Close sidebar"].tap()
      app.buttons["New"].tap()
      tap(app.buttons["New reminder"], route: "reminder.quick", ready: element("quick.title"))
      // Cancel preserves the Add/Apply boundary and creates no reminder or user data.
      app.buttons["Cancel"].firstMatch.tap()
      app.buttons["Reminders"].firstMatch.tap()
      let home = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home, '")).firstMatch
      tap(home, route: "reminders.list", ready: app.staticTexts["Buy milk"])
      tap(
        app.staticTexts["Buy milk"], route: "reminder.editor",
        ready: app.descendants(matching: .any)["task.title"].firstMatch)
      XCTAssertEqual(
        app.descendants(matching: .any)["task.title"].firstMatch.value as? String, "Buy milk")
      app.buttons["Cancel"].firstMatch.tap()
      XCTAssertTrue(app.staticTexts["Buy milk"].exists)
      app.navigationBars.buttons["Lists"].tap()
      app.buttons["Today"].firstMatch.tap()
    }
  }
}

import XCTest

/// Automation-inclusive latency samples, not touch-to-photon or shipping-device benchmarks.
/// Source fixtures are shared with normal journeys; no real Apple accounts or stores are used.
@MainActor
final class PerformanceBaselineTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments =
        TestData.launchArguments + [
          "-uiTestingNow", "09:41", "-today.setting.healthSummary", "YES",
        ]
    }
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  private func sample(_ name: String, _ body: () -> Void) {
    let start = ProcessInfo.processInfo.systemUptime
    body()
    print("PERF_SAMPLE \(name) \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
  }

  private func tap(_ button: XCUIElement, ready: XCUIElement) {
    button.tap()
    XCTAssertTrue(ready.waitForExistence(timeout: 5))
  }

  func testLaunchAndResume() {
    for _ in 0..<3 {
      app.terminate()
      sample("process_launch_to_usable_automation") {
        app.launch()
        XCTAssertTrue(app.buttons["Ask AI or add anything"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New"].isHittable)
        XCTAssertTrue(app.weekStripDay(.now).exists)
      }
      let probe = app.staticTexts["coldStartMs"]
      XCTAssertTrue(probe.waitForExistence(timeout: 5))
      print("PERF_SAMPLE process_to_onAppear \(probe.label) ms")
      XCUIDevice.shared.press(.home)
      sample("resume_to_usable_automation") {
        app.activate()
        let usable = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["New"])
        XCTAssertEqual(XCTWaiter().wait(for: [usable], timeout: 5), .completed)
      }
    }
  }

  func testNavigation() {
    app.launch()
    for _ in 0..<3 {
      sample("today_to_week") {
        tap(app.buttons["Calendar"].firstMatch, ready: element("calendar.dayGrid"))
      }
      sample("week_to_month") {
        tap(app.buttons["calendar.mode.month"], ready: element("calendar.monthPager"))
      }
      sample("month_to_year") {
        tap(app.buttons["calendar.mode.year"], ready: element("calendar.year.scroll"))
      }
      app.buttons["calendar.mode.twoday"].tap()
      sample("calendar_to_reminders") {
        tap(app.buttons["Reminders"].firstMatch, ready: element("list.Work"))
      }
      sample("reminders_to_clock") {
        tap(app.buttons["Clock"].firstMatch, ready: app.buttons["World Clock"])
      }
      sample("clock_to_today") {
        tap(app.buttons["Today"].firstMatch, ready: app.weekStripDay(.now))
      }
    }
    // Health may be above the automatic scroll-to-now position; reveal outside the timed interval.
    let health = app.buttons["health.summary"]
    for _ in 0..<4 where !health.isHittable { app.swipeDown() }
    sample("open_health") { tap(health, ready: app.buttons["health.row.steps"]) }
    app.buttons["Done"].firstMatch.tap()
    app.buttons["Open menu"].tap()
    sample("open_settings") {
      tap(app.buttons["Settings"].firstMatch, ready: app.navigationBars["Settings"])
    }
  }

  func testScrollMetrics() {
    app.launch()
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.year"].tap()
    let scroll = element("calendar.year.scroll")
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(
      metrics: [
        XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric,
      ], options: options
    ) {
      scroll.swipeUp()
      scroll.swipeDown()
    }
  }

  func testCreateCompleteSearchAndApply() {
    app.launch()
    app.buttons["Reminders"].firstMatch.tap()
    sample("open_quick_create") {
      app.buttons["New"].tap()
      tap(app.buttons["New reminder"], ready: element("quick.title"))
    }
    element("quick.title").typeText("Performance baseline reminder")
    sample("save_quick_create") {
      app.buttons["quick.save"].tap()
      XCTAssertTrue(app.buttons["quick.save"].waitForNonExistence(timeout: 5))
    }
    element("list.Work").tap()
    let title = app.staticTexts["Prepare the demo"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    sample("open_reminder") {
      tap(title, ready: app.descendants(matching: .any)["task.title"].firstMatch)
    }
    app.buttons["Cancel"].tap()
    sample("complete_reminder") {
      app.buttons["Complete Prepare the demo"].tap()
      XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }
    app.buttons["Open menu"].tap()
    sample("open_search") { tap(app.buttons["Search"], ready: app.textFields["search.field"]) }
    sample("search_milk_including_typing") {
      app.textFields["search.field"].typeText("milk")
      XCTAssertTrue(
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Buy milk'"))
          .firstMatch.waitForExistence(timeout: 5))
    }
  }
}

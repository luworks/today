import XCTest

/// Native app-target metrics are distinct from app layout proxies and sampled RSS.
@MainActor
final class PageScrollResourceTests: XCTestCase {
  func testYearNativeScrollResources() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = TestData.launchArguments + ["-uiTestingNow", "09:41"]
    app.launch()
    XCTAssertTrue(app.buttons["Calendar"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.year"].tap()
    let scroll = app.descendants(matching: .any)["calendar.year.scroll"].firstMatch
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    XCTAssertTrue(scroll.isHittable)
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    options.invocationOptions = .manuallyStop
    print(
      "PERF_RESOURCE_CONTEXT Year native scroll; three measured iterations plus one discarded warmup; fast upward scroll; downward reset excluded; missing provider metrics are not zero."
    )
    measure(
      metrics: [XCTMemoryMetric(application: app), XCTHitchMetric(application: app)],
      options: options
    ) {
      scroll.swipeUp(velocity: .fast)
      stopMeasuring()
      scroll.swipeDown(velocity: .fast)
      XCTAssertTrue(scroll.exists)
      XCTAssertTrue(scroll.isHittable)
    }
  }
}

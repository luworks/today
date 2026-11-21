import Foundation
import XCTest

@testable import TodayCore

final class HealthCatalogTests: XCTestCase {
  func testOldSelectionsKeepTheirStableIdentityAndNewMetricsRoundTrip() {
    let data = Data(#"["steps","sleep","weight","restingHeartRate","bodyFat"]"#.utf8)
    XCTAssertEqual(
      HealthSelection.decoded(data).shown, [.steps, .sleep, .weight, .restingHeartRate, .bodyFat])
    let expanded = HealthSelection(shown: [.dietaryWater, .heartRate, .weight])
    XCTAssertEqual(HealthSelection.decoded(expanded.encoded()), expanded)
    XCTAssertEqual(HealthMetric.defaults, [.steps, .sleep, .weight])
  }

  func testNutritionUsesDailyTotalsAndRatesNeverBecomeCumulativeBars() {
    XCTAssertEqual(HealthCatalog.quantities[.dietaryWater]?.aggregation, .dailySum)
    XCTAssertEqual(HealthCatalog.quantities[.dietaryEnergyConsumed]?.aggregation, .dailySum)
    XCTAssertEqual(HealthCatalog.quantities[.heartRate]?.aggregation, .dailyAverage)
    XCTAssertEqual(HealthCatalog.quantities[.cyclingPower]?.aggregation, .dailyAverage)
    XCTAssertEqual(HealthCatalog.quantities[.weight]?.aggregation, .samples)
    XCTAssertTrue(HealthMetric.sleep.isCumulative)
    XCTAssertTrue(HealthMetric.mindfulMinutes.isCumulative)
    XCTAssertFalse(HealthMetric.heartRate.isCumulative)
    XCTAssertEqual(
      HealthFormat.value(.oxygenSaturation, 98, locale: Locale(identifier: "en_US")).text, "98.0%")
    XCTAssertEqual(
      HealthFormat.value(.bloodGlucose, 95, locale: Locale(identifier: "en_US")).text, "95.0 mg/dL")
    XCTAssertEqual(HealthCatalog.quantities[.dietaryVitaminD]?.label, "µg")
    XCTAssertEqual(HealthCatalog.quantities[.dietarySodium]?.scale, 1_000)
  }

  func testMindfulIntervalsDeduplicateOverlapClipFutureAndSplitAtDSTMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
      calendar.date(
        from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }
    let start = date(7, 0)
    let end = date(9, 0)
    let first = DateInterval(start: date(7, 23, 30), end: date(8, 0, 30))
    let overlap = DateInterval(start: date(8, 0), end: date(8, 1))
    let future = DateInterval(start: date(8, 23, 45), end: date(9, 1))
    let points = HealthDurationMath.dailyMinutes(
      [first, first, overlap, future], start: start, end: end, calendar: calendar)
    XCTAssertEqual(points.map(\.value), [30, 75])
    XCTAssertEqual(points.map(\.date), [date(7, 0), date(8, 0)])
    let wholeDSTDay = HealthDurationMath.dailyMinutes(
      [DateInterval(start: date(8, 0), end: date(9, 0))], start: start, end: end, calendar: calendar
    )
    XCTAssertEqual(wholeDSTDay.first?.value, 23 * 60)
  }
}

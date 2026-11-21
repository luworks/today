import XCTest

@testable import TodayCore
@testable import TodayData

final class MovingAverageTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private func date(_ day: Int, month: Int = 10, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func point(_ day: Int, _ value: Double, hour: Int = 12) -> HealthPoint {
    HealthPoint(date: date(day, hour: hour), value: value)
  }

  private func average(_ points: [HealthPoint], window: Int = 7, days: Int = 7) -> [HealthPoint] {
    MovingAverage.series(
      points: points, window: window,
      days: HealthWindow(days: days, now: date(17), calendar: calendar), calendar: calendar)
  }

  func testSteadyReadingsStayFlat() {
    let result = average((5...17).map { point($0, 70) })
    XCTAssertEqual(result.count, 7)
    XCTAssertTrue(result.allSatisfy { $0.value == 70 })
    XCTAssertEqual(result.first?.date, date(11, hour: 0))
    XCTAssertEqual(result.last?.date, date(17, hour: 0))
  }

  func testNoisyReadingsUseAllSamplesRatherThanDailyLastValues() {
    let result = average([point(17, 60, hour: 8), point(17, 90, hour: 10), point(16, 60)], days: 1)
    XCTAssertEqual(result.map(\.value), [70])
    XCTAssertEqual(
      average([point(17, 90), point(16, 60), point(15, 60)], days: 1).map(\.value), [70])
  }

  func testGapsNeverAddZerosAndInsufficientWindowsStayAbsent() {
    let result = average(
      [point(5, 60), point(6, 80), point(16, 90), point(17, 110)], window: 3, days: 13)
    XCTAssertEqual(result.map(\.date), [date(6, hour: 0), date(7, hour: 0), date(17, hour: 0)])
    XCTAssertEqual(result.map(\.value), [70, 70, 100])
    XCTAssertEqual(MovingAverage.segments(result, calendar: calendar).map(\.count), [2, 1])
  }

  func testSingleSampleAndEmptyDataProduceNoAverage() {
    XCTAssertTrue(average([point(17, 70)]).isEmpty)
    XCTAssertTrue(average([]).isEmpty)
    XCTAssertTrue(average([point(16, 70), point(17, 80)], window: 0).isEmpty)
  }

  func testWindowLongerThanDataStillUsesTwoAvailableSamples() {
    XCTAssertEqual(average([point(16, 60), point(17, 80)], window: 14, days: 1).map(\.value), [70])
  }

  func testPreRangeSamplesAndExactCalendarBoundaries() {
    let points = [
      point(10, 1_000), point(11, 60, hour: 0), point(16, 80),
      point(17, 100, hour: 23), point(18, 1_000, hour: 0),
    ]
    XCTAssertEqual(average(points, days: 1).map(\.value), [80])
    XCTAssertEqual(
      average([point(5, 60), point(10, 80)], days: 7).first?.value, 70,
      "the first visible day includes readings before its start")
  }

  func testDSTSpringForwardAndFallBackUseWholeLocalDays() {
    for (month, day, hours) in [(3, 8, 23.0), (11, 1, 25.0)] {
      let now = date(day, month: month)
      let start = calendar.startOfDay(for: now)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      let previous = calendar.date(byAdding: .day, value: -1, to: start)!
      XCTAssertEqual(end.timeIntervalSince(start) / 3600, hours)
      let points = [
        HealthPoint(date: previous.addingTimeInterval(-1), value: 1_000),
        HealthPoint(date: previous, value: 60),
        HealthPoint(date: end.addingTimeInterval(-1), value: 80),
        HealthPoint(date: end, value: 1_000),
      ]
      let result = MovingAverage.series(
        points: points, window: 2,
        days: HealthWindow(days: 1, now: now, calendar: calendar), calendar: calendar)
      XCTAssertEqual(result, [HealthPoint(date: start, value: 70)])
    }
  }
}

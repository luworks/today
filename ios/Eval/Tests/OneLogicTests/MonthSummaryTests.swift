import XCTest

@testable import TodayCore

final class MonthSummaryTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func entry(
    _ start: Date, _ end: Date, _ title: String, _ tint: Int,
    allDay: Bool = false, alarm: Bool = false
  ) -> MonthSummaryEntry {
    MonthSummaryEntry(
      start: start, end: end, isAllDay: allDay, title: title, isAlarm: alarm, tintIndex: tint)
  }

  func testOrderingCountsAndAlarmMarkers() {
    let day = date(10, 10)
    let entries = [
      entry(date(10, 10, 7), date(10, 10, 7), "Alarm", 9, alarm: true),
      entry(date(10, 10, 9), date(10, 10, 10), "Z", 3),
      entry(day, date(10, 11), "All day", 1, allDay: true),
      entry(date(10, 10, 9), date(10, 10, 10), "A", 2),
      entry(date(10, 10, 8), date(10, 10, 8), "Alarm 2", 8, alarm: true),
    ]
    let result = MonthSummary.summarize(days: [day], entries: entries, calendar: calendar)[0]
    XCTAssertEqual(result.eventCount, 3)
    XCTAssertEqual(result.alarmCount, 2)
    XCTAssertEqual(result.tintIndices, [1, 2, 3])
    let alarmsOnly = MonthSummary.summarize(
      days: [day], entries: entries.filter(\.isAlarm), calendar: calendar)[0]
    XCTAssertEqual(alarmsOnly.tintIndices, [9, 8])
  }

  func testOverlapExclusiveEndsMidnightPointsAndEmptyDays() {
    let days = [
      date(12, 30), date(12, 31), calendar.date(byAdding: .day, value: 1, to: date(12, 31))!,
    ]
    let entries = [
      entry(date(12, 30), date(12, 31), "All day", 1, allDay: true),
      entry(date(12, 30, 23), date(12, 31, 1), "Crossing", 2),
      entry(date(12, 31), date(12, 31), "Midnight", 3, alarm: true),
    ]
    let result = MonthSummary.summarize(days: days, entries: entries, calendar: calendar)
    XCTAssertEqual(result.map(\.day), days)
    XCTAssertEqual(result.map(\.eventCount), [2, 1, 0])
    XCTAssertEqual(result.map(\.alarmCount), [0, 1, 0])
    XCTAssertEqual(result.map(\.tintIndices), [[1, 2], [2, 3], []])
  }

  func testFullDayTimedSpanAndClippedStartSortLikeCalendarEntries() {
    let day = date(10, 10)
    let entries = [
      entry(date(10, 9, 22), date(10, 10, 2), "B", 3),
      entry(day, date(10, 11), "Z", 2),
      entry(date(10, 9, 12), date(10, 11, 12), "A", 1),
      entry(day, date(10, 10, 1), "A", 4),
    ]
    let result = MonthSummary.summarize(days: [day], entries: entries, calendar: calendar)[0]
    XCTAssertEqual(result.eventCount, 4)
    XCTAssertEqual(result.tintIndices, [1, 2, 4])
  }

  func testDSTDaysUseCalendarBoundaries() {
    for (month, day) in [(3, 8), (11, 1)] {
      let start = date(month, day)
      let end = calendar.date(byAdding: .day, value: 1, to: start)!
      let result = MonthSummary.summarize(
        days: [start, end],
        entries: [entry(start, end, "All day", 4, allDay: true)], calendar: calendar)
      XCTAssertEqual(result.map(\.eventCount), [1, 0])
      XCTAssertEqual(result.map(\.tintIndices), [[4], []])
    }
  }

  func testEqualSortKeysRetainInputOrderAndDuplicateTints() {
    let start = date(10, 10, 9)
    let entries = [
      entry(start, start, "Same", 7), entry(start, start, "Same", 7),
      entry(start, start, "Same", 8),
    ]
    XCTAssertEqual(
      MonthSummary.summarize(days: [start], entries: entries, calendar: calendar)[0].tintIndices,
      [7, 7, 8])
  }
}

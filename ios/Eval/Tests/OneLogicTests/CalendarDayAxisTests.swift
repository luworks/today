import XCTest

@testable import TodayCore

final class CalendarDayAxisTests: XCTestCase {
  func testNowBelongsOnlyToLocalTodayAndUsesFoldedAxis() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T09:45:00Z"))
    let today = cal.startOfDay(for: now)
    XCTAssertNil(
      CalendarDayAxis.currentMinute(
        on: cal.date(byAdding: .day, value: -1, to: today)!, now: now, calendar: cal))
    XCTAssertNil(
      CalendarDayAxis.currentMinute(
        on: cal.date(byAdding: .day, value: 1, to: today)!, now: now, calendar: cal))
    let minute = try XCTUnwrap(CalendarDayAxis.currentMinute(on: today, now: now, calendar: cal))
    XCTAssertEqual(minute, 105)
    let gap = CalendarGapLayout.Interval(start: 0, end: 1440)
    for expanded: Set<CalendarGapLayout.Interval> in [[], [gap]] {
      let axis = CalendarGapLayout(
        days: [.init()], pointsPerHour: 60,
        minimumGapMinutes: 120, compressedGapHeight: 44, expandedGaps: expanded)
      XCTAssertEqual(axis.minute(atY: axis.y(forMinute: minute)), 105, accuracy: 0.001)
      XCTAssertEqual(
        axis.y(forMinute: minute), expanded.isEmpty ? 105 * 44 / 1440 : 105, accuracy: 0.001)
    }
  }

  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  func testClockPositionsOnRollbackSpringForwardAndOrdinaryDays() {
    for day in ["2026-11-01", "2026-03-08", "2026-10-29"] {
      let offset = day == "2026-10-29" || day == "2026-03-08" ? "-07:00" : "-08:00"
      for (clock, minute) in [("08:00", 480.0), ("10:00", 600), ("11:16", 676), ("23:59", 1439)] {
        let instant = date("\(day)T\(clock):00\(offset)")
        XCTAssertEqual(CalendarDayAxis.minute(instant, calendar: calendar), minute)
        let interval = calendar.dateInterval(of: .day, for: instant)!
        let span = CalendarDayAxis.span(
          start: instant, end: instant.addingTimeInterval(600), in: interval, calendar: calendar)
        XCTAssertEqual(span.start, minute)
        XCTAssertEqual(span.end, min(1440, minute + 30))
      }
    }
  }

  func testRepeatedHourSharesClockCoordinateAndRetainsVisibleEvent() {
    let first = date("2026-11-01T01:45:00-07:00")
    let second = date("2026-11-01T01:45:00-08:00")
    XCTAssertEqual(second.timeIntervalSince(first), 3600)
    XCTAssertEqual(CalendarDayAxis.minute(first, calendar: calendar), 105)
    XCTAssertEqual(CalendarDayAxis.minute(second, calendar: calendar), 105)
    let span = CalendarDayAxis.span(
      start: first, end: date("2026-11-01T01:15:00-08:00"),
      in: calendar.dateInterval(of: .day, for: first)!, calendar: calendar)
    XCTAssertEqual(span.start, 105)
    XCTAssertEqual(span.end, 135)
  }

  func testTransitionSpanningEventsUseClockEndpoints() {
    for (start, end) in [
      ("2026-11-01T00:30:00-07:00", "2026-11-01T03:30:00-08:00"),
      ("2026-03-08T00:30:00-08:00", "2026-03-08T03:30:00-07:00"),
    ] {
      let s = date(start)
      let span = CalendarDayAxis.span(
        start: s, end: date(end), in: calendar.dateInterval(of: .day, for: s)!,
        calendar: calendar)
      XCTAssertEqual(span.start, 30)
      XCTAssertEqual(span.end, 210)
    }
  }

  func testCrossDayClippingUsesMidnightAt1440OnShortAndLongDays() {
    for (start, end) in [
      ("2026-10-31T23:30:00-07:00", "2026-11-02T00:30:00-08:00"),
      ("2026-03-07T23:30:00-08:00", "2026-03-09T00:30:00-07:00"),
    ] {
      let s = date(start)
      let e = date(end)
      let middle = calendar.date(byAdding: .day, value: 1, to: s)!
      let full = CalendarDayAxis.span(
        start: s, end: e, in: calendar.dateInterval(of: .day, for: middle)!, calendar: calendar)
      XCTAssertEqual(full.start, 0)
      XCTAssertEqual(full.end, 1440)
      let tail = CalendarDayAxis.span(
        start: s, end: e, in: calendar.dateInterval(of: .day, for: e)!, calendar: calendar)
      XCTAssertEqual(tail.start, 0)
      XCTAssertEqual(tail.end, 30)
      let head = CalendarDayAxis.span(
        start: s, end: e, in: calendar.dateInterval(of: .day, for: s)!, calendar: calendar)
      XCTAssertEqual(head.start, 1410)
      XCTAssertEqual(head.end, 1440)
    }
  }
}

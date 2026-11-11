import XCTest

@testable import TodayCore

final class MonthLabelTests: XCTestCase {
  func testCurrentMonthRollsOverInLocalTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let boundary = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(
      MonthLabel.text(
        now: boundary.addingTimeInterval(-1), calendar: calendar,
        locale: locale), "Dec 2026")
    XCTAssertEqual(MonthLabel.text(now: boundary, calendar: calendar, locale: locale), "Jan 2027")
    var utc = calendar
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    XCTAssertEqual(
      MonthLabel.text(
        now: boundary.addingTimeInterval(-1), calendar: utc,
        locale: locale), "Jan 2027")
    XCTAssertEqual(
      MonthLabel.text(
        now: boundary, length: .full, calendar: calendar,
        locale: locale), "January 2027")
    XCTAssertEqual(
      MonthLabel.text(
        now: boundary, calendar: calendar,
        locale: Locale(identifier: "ja_JP")), "2027年1月")
  }

  func testBrowsedPagesCrossYearInBothDirectionsWithoutSelectingAnotherDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let selected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11))!
    let december = CalendarMath.monthStart(offset: 1, from: selected, calendar: calendar)
    let january = CalendarMath.monthStart(offset: 2, from: selected, calendar: calendar)
    let locale = Locale(identifier: "en_US")
    // The selection/clock stays in November while the committed visible page moves.
    for (page, expected) in [(december, "Dec 2026"), (january, "Jan 2027"), (december, "Dec 2026")]
    {
      let period = MonthLabel.period(now: selected, visibleDays: page...page)
      XCTAssertEqual(MonthLabel.text(period: period, calendar: calendar, locale: locale), expected)
    }
    let period = MonthLabel.period(now: selected, visibleDays: january...january)
    XCTAssertEqual(
      MonthLabel.text(period: period, length: .full, calendar: calendar, locale: locale),
      "January 2027")
  }

  func testTwoDayUsesFirstColumnAcrossYearBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
    let january = calendar.date(byAdding: .day, value: 1, to: december)!
    let next = calendar.date(byAdding: .day, value: 1, to: january)!
    XCTAssertEqual(
      MonthLabel.period(now: january, visibleDays: december...january), .month(december))
    XCTAssertEqual(
      MonthLabel.period(now: december, visibleDays: january...next), .month(january))
    XCTAssertEqual(
      MonthLabel.period(now: january, visibleDays: december...january), .month(december))
  }

  func testYearOtherTabsAndTodayReset() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11))!
    let browsed = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    let year = MonthLabel.period(now: now, visibleDays: browsed...browsed, showsYear: true)
    XCTAssertEqual(
      MonthLabel.text(period: year, calendar: calendar, locale: Locale(identifier: "en_US")),
      "2027")
    XCTAssertEqual(
      MonthLabel.text(
        period: year, length: .full, calendar: calendar, locale: Locale(identifier: "ja_JP")),
      "2027年")
    XCTAssertEqual(MonthLabel.period(now: now, visibleDays: nil, showsYear: true), .month(now))
    XCTAssertEqual(MonthLabel.period(now: now, visibleDays: now...now), .month(now))
    // Picking January from Year must name that month, rather than the wall-clock month.
    XCTAssertEqual(MonthLabel.period(now: now, visibleDays: browsed...browsed), .month(browsed))
  }

}

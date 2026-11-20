import XCTest

@testable import TodayCore

final class MonthWeekStripTests: XCTestCase {
  private func calendar(firstWeekday: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = firstWeekday
    return calendar
  }

  private func date(_ month: Int, _ day: Int, _ hour: Int = 0, year: Int = 2026) -> Date {
    calendar(firstWeekday: 1).date(
      from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  func testWeekStartFollowsFirstWeekday() {
    let sunday = calendar(firstWeekday: 1)
    let monday = calendar(firstWeekday: 2)
    XCTAssertEqual(MonthWeekStrip.weekStart(of: date(11, 20, 15), calendar: sunday), date(11, 15))
    XCTAssertEqual(MonthWeekStrip.weekStart(of: date(11, 20, 15), calendar: monday), date(11, 16))
    XCTAssertEqual(MonthWeekStrip.weekStart(of: date(11, 15), calendar: monday), date(11, 9))
    XCTAssertEqual(MonthWeekStrip.weekStart(of: date(11, 15), calendar: sunday), date(11, 15))
  }

  func testDaysOfWeekCrossMonthAndDST() {
    let monday = calendar(firstWeekday: 2)
    XCTAssertEqual(
      MonthWeekStrip.days(ofWeek: date(11, 1), calendar: monday),
      [
        date(10, 26), date(10, 27), date(10, 28), date(10, 29), date(10, 30), date(10, 31),
        date(11, 1),
      ])
    let sunday = calendar(firstWeekday: 1)
    XCTAssertEqual(
      MonthWeekStrip.days(ofWeek: date(12, 31), calendar: sunday).last, date(1, 2, year: 2027))
  }

  func testWeekOffsetsAndShifts() {
    let sunday = calendar(firstWeekday: 1)
    let reference = date(11, 20)
    XCTAssertEqual(
      MonthWeekStrip.weekOffset(of: date(11, 21, 23), from: reference, calendar: sunday), 0)
    XCTAssertEqual(
      MonthWeekStrip.weekOffset(of: date(11, 22), from: reference, calendar: sunday), 1)
    XCTAssertEqual(
      MonthWeekStrip.weekOffset(of: date(11, 14), from: reference, calendar: sunday), -1)
    XCTAssertEqual(
      MonthWeekStrip.weekOffset(of: date(10, 31), from: reference, calendar: sunday), -3)
    XCTAssertEqual(MonthWeekStrip.week(-3, from: reference, calendar: sunday), date(10, 25))
    XCTAssertEqual(MonthWeekStrip.shifted(date(10, 28, 9), weeks: 1, calendar: sunday), date(11, 4))
  }

  func testRowOfDayInMonthWeeks() {
    let sunday = calendar(firstWeekday: 1)
    let monday = calendar(firstWeekday: 2)
    let weeksSunday = CalendarMath.monthWeeks(of: date(11, 1), calendar: sunday)
    let weeksMonday = CalendarMath.monthWeeks(of: date(11, 1), calendar: monday)
    XCTAssertEqual(
      MonthWeekStrip.row(of: date(11, 20), inMonthWeeks: weeksSunday, calendar: sunday), 2)
    XCTAssertEqual(
      MonthWeekStrip.row(of: date(11, 1), inMonthWeeks: weeksMonday, calendar: monday), 0)
    XCTAssertEqual(
      MonthWeekStrip.row(of: date(11, 2), inMonthWeeks: weeksMonday, calendar: monday), 1)
    XCTAssertEqual(
      MonthWeekStrip.row(of: date(11, 30), inMonthWeeks: weeksMonday, calendar: monday), 5)
  }

  func testDragProgressAndSnap() {
    XCTAssertEqual(MonthWeekStrip.progress(collapsed: false, translation: -100, distance: 200), 0.5)
    XCTAssertEqual(MonthWeekStrip.progress(collapsed: false, translation: 50, distance: 200), 0)
    XCTAssertEqual(MonthWeekStrip.progress(collapsed: true, translation: 50, distance: 200), 0.75)
    XCTAssertEqual(MonthWeekStrip.progress(collapsed: true, translation: -50, distance: 200), 1)
    XCTAssertTrue(
      MonthWeekStrip.settlesCollapsed(progress: 0.2, predictedTranslation: -150, distance: 200))
    XCTAssertFalse(
      MonthWeekStrip.settlesCollapsed(progress: 0.8, predictedTranslation: 150, distance: 200))
    XCTAssertTrue(
      MonthWeekStrip.settlesCollapsed(progress: 0.6, predictedTranslation: 0, distance: 200))
    XCTAssertFalse(
      MonthWeekStrip.settlesCollapsed(progress: 0.4, predictedTranslation: 0, distance: 200))
  }
}

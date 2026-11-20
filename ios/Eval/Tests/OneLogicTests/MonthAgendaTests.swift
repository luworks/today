import XCTest

@testable import TodayCore

final class MonthAgendaTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private func item(_ start: Date, _ end: Date, _ title: String, allDay: Bool = false)
    -> MonthAgendaItem
  {
    MonthAgendaItem(start: start, end: end, isAllDay: allDay, title: title)
  }

  func testDaysStepByCalendarDayAcrossDST() {
    let days = MonthAgenda.days(around: date(11, 1, 15), before: 1, after: 1, calendar: calendar)
    XCTAssertEqual(days, [date(10, 31), date(11, 1), date(11, 2)])
    let more = MonthAgenda.appending(
      2, to: MonthAgenda.prepending(1, to: days, calendar: calendar), calendar: calendar)
    XCTAssertEqual(more.first, date(10, 30))
    XCTAssertEqual(more.last, date(11, 4))
    XCTAssertEqual(more.count, 6)
    XCTAssertTrue(MonthAgenda.contains(date(11, 4, 23), in: more, calendar: calendar))
    XCTAssertFalse(MonthAgenda.contains(date(11, 5), in: more, calendar: calendar))
  }

  func testSectionsBucketMultiDayAllDayAndPointsInCalendarOrder() {
    let days = MonthAgenda.days(from: date(11, 20), count: 3, calendar: calendar)
    let items = [
      item(date(11, 20, 9), date(11, 20, 10), "Z"),
      item(date(11, 20), date(11, 21), "Holiday", allDay: true),
      item(date(11, 20, 22), date(11, 22, 2), "Trip"),
      item(date(11, 20, 7, 40), date(11, 20, 7, 40), "Alarm"),
      item(date(11, 22), date(11, 22), "Midnight"),
      item(date(11, 20, 9), date(11, 20, 9, 30), "A"),
      item(date(11, 10), date(11, 11), "Before", allDay: true),
    ]
    let sections = MonthAgenda.sections(days: days, items: items, calendar: calendar)
    XCTAssertEqual(sections[0].map { items[$0].title }, ["Holiday", "Alarm", "A", "Z", "Trip"])
    XCTAssertEqual(sections[1].map { items[$0].title }, ["Trip"])
    XCTAssertEqual(sections[2].map { items[$0].title }, ["Midnight", "Trip"])
  }

  func testSectionsKeepExclusiveAllDayEndOnDSTDay() {
    let days = MonthAgenda.days(from: date(11, 1), count: 2, calendar: calendar)
    let sections = MonthAgenda.sections(
      days: days, items: [item(date(11, 1), date(11, 2), "Fall back", allDay: true)],
      calendar: calendar)
    XCTAssertEqual(sections, [[0], []])
  }

  func testTopDayIsTheRowStraddlingTheTopEdge() {
    let a = date(11, 20)
    let b = date(11, 21)
    let c = date(11, 22)
    let rows = [
      MonthAgendaRowFrame(day: a, minY: -400, maxY: -360),
      MonthAgendaRowFrame(day: b, minY: -20, maxY: 30),
      MonthAgendaRowFrame(day: c, minY: 30, maxY: 60),
    ]
    XCTAssertEqual(MonthAgenda.topDay(rows: rows, top: 0), b)
    XCTAssertEqual(MonthAgenda.topDay(rows: rows, top: 30), c)
    XCTAssertEqual(MonthAgenda.topDay(rows: Array(rows.dropFirst(2)), top: 0), c)
    XCTAssertNil(MonthAgenda.topDay(rows: [], top: 0))
  }

  func testRelativeNames() {
    let now = date(11, 20, 23, 30)
    XCTAssertEqual(
      MonthAgenda.relative(date(11, 19, 8), today: now, calendar: calendar), .yesterday)
    XCTAssertEqual(MonthAgenda.relative(date(11, 20), today: now, calendar: calendar), .today)
    XCTAssertEqual(MonthAgenda.relative(date(11, 21, 1), today: now, calendar: calendar), .tomorrow)
    XCTAssertNil(MonthAgenda.relative(date(11, 22), today: now, calendar: calendar))
  }
}

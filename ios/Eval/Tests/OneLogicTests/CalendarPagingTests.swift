import XCTest

@testable import TodayCore

final class CalendarPagingTests: XCTestCase {
  func testInitialPositionAndResizingKeepTheRequestedDistantMonth() {
    for rowHeight in [51.0, 62.4, 70.5] {
      let height = CalendarPaging.monthPageHeight(rowHeight: rowHeight)
      XCTAssertEqual(
        CalendarPaging.targetOffset(
          original: 0, proposed: 360 * height, velocity: 0,
          pageLength: height, contentLength: 721 * height, limitsToAdjacent: false),
        360 * height)
      XCTAssertEqual(
        CalendarPaging.targetOffset(
          original: 360 * 306, proposed: 372 * height, velocity: 0,
          pageLength: height, contentLength: 721 * height, limitsToAdjacent: false),
        372 * height)
    }
  }
  private func month(_ year: Int, _ month: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: 1))!
  }

  func testPageBoundsContainEveryWeekAcrossCompactMonthsAndWeekStarts() {
    for firstWeekday in [1, 2] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.firstWeekday = firstWeekday
      calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
      for rowHeight in [51.0, 70.5] {
        let stride = CalendarPaging.monthPageHeight(rowHeight: rowHeight)
        let months = (0..<28).map {
          CalendarMath.monthStart(
            offset: $0, from: month(2026, 11, calendar: calendar), calendar: calendar)
        }
        for (index, date) in months.enumerated() {
          let weeks = CalendarMath.monthWeeks(of: date, calendar: calendar)
          let origin = Double(index) * stride
          let end = origin + Double(weeks.count) * rowHeight
          XCTAssertLessThanOrEqual(end, origin + stride)
          let days = weeks.flatMap { $0 }.compactMap { $0 }
          XCTAssertEqual(days.first, date)
          XCTAssertEqual(days.count, calendar.range(of: .day, in: .month, for: date)!.count)
          for (row, week) in weeks.enumerated() {
            for (column, day) in week.enumerated() {
              guard let day else { continue }
              XCTAssertEqual(
                (calendar.component(.weekday, from: day) - firstWeekday + 7) % 7, column)
              XCTAssertLessThanOrEqual(origin + Double(row + 1) * rowHeight, end)
            }
          }
        }
        if firstWeekday == 2 {
          XCTAssertEqual(CalendarMath.monthWeeks(of: months[0], calendar: calendar).count, 6)
          XCTAssertEqual(CalendarMath.monthWeeks(of: months[2], calendar: calendar).count, 5)
          XCTAssertEqual(CalendarMath.monthWeeks(of: months[3], calendar: calendar).count, 4)
          XCTAssertEqual(CalendarMath.monthWeeks(of: months[15], calendar: calendar).count, 5)
        }
      }
    }
  }

  func testSettledTargetsStayOnPageLatticeDuringFlicksReversalAndRubberBand() {
    for height in [306.0, 423.0] {
      func target(_ original: Double, _ proposed: Double, _ velocity: Double) -> Double {
        CalendarPaging.targetOffset(
          original: original * height, proposed: proposed * height, velocity: velocity,
          pageLength: height, contentLength: 721 * height) / height
      }
      XCTAssertEqual(target(360, 365, 4000), 361)
      XCTAssertEqual(target(361, 350, -4000), 360)
      XCTAssertEqual(target(360, 360.1, 0), 360)
      XCTAssertEqual(target(360, 360.01, 500), 361)
      XCTAssertEqual(target(360, 359.99, -500), 359)
      // A second drag can start between pages; it must not perpetuate a fractional origin.
      XCTAssertEqual(target(360.3, 359.8, -400), 359)
      XCTAssertEqual(target(360.7, 361.2, 400), 362)
      XCTAssertEqual(target(-0.2, -2, -500), 0)
      XCTAssertEqual(target(720.2, 724, 500), 720)
      XCTAssertEqual(target(720, 718, -500), 719)
    }
  }

  func testCompactHeightChangesDoNotChangeTheNextOrPreviousPageOrigin() {
    let height = CalendarPaging.monthPageHeight(rowHeight: 51)
    var offset = 360.0 * height
    // November -> December -> January -> four-week February -> March, then back.
    for direction in [1.0, 1, 1, 1, -1, -1, -1, -1] {
      let next = CalendarPaging.targetOffset(
        original: offset, proposed: offset + direction * 200, velocity: direction * 500,
        pageLength: height, contentLength: 721 * height)
      XCTAssertEqual(next, offset + direction * height)
      offset = next
    }
    XCTAssertEqual(offset, 360 * height)
  }
  func testTwoColumnFlickAdvancesOneDayAcrossFebruaryBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let february = month(2027, 2, calendar: calendar)
    let start = calendar.date(byAdding: .day, value: 27, to: february)!
    let columnWidth = 194.0
    let offset = CalendarPaging.targetOffset(
      original: 360 * columnWidth, proposed: 364 * columnWidth, velocity: 4000,
      pageLength: columnWidth, contentLength: 721 * columnWidth, visiblePages: 2)
    let days = Int(offset / columnWidth) - 360
    XCTAssertEqual(days, 1)
    XCTAssertEqual(
      calendar.date(byAdding: .day, value: days, to: start), month(2027, 3, calendar: calendar))
    XCTAssertEqual(
      CalendarPaging.targetOffset(
        original: offset, proposed: offset - 4 * columnWidth, velocity: -4000,
        pageLength: columnWidth, contentLength: 721 * columnWidth, visiblePages: 2),
      360 * columnWidth)
    XCTAssertEqual(
      CalendarPaging.targetOffset(
        original: 719 * columnWidth, proposed: 724 * columnWidth, velocity: 4000,
        pageLength: columnWidth, contentLength: 721 * columnWidth, visiblePages: 2),
      719 * columnWidth, "The last first-column position must leave a second day visible.")
  }

}

import Foundation
import TodayCore
import XCTest

final class SettleGateTests: XCTestCase {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  func testOnlyTheCurrentDayHasSettle() {
    let now = date(1, 9, 41)
    XCTAssertTrue(SettleGate.applies(to: date(1, 0), now: now, calendar: calendar))
    XCTAssertTrue(SettleGate.applies(to: date(1, 23, 59), now: now, calendar: calendar))
    XCTAssertFalse(
      SettleGate.applies(to: date(31, 23, 59, month: 10), now: now, calendar: calendar))
    XCTAssertFalse(SettleGate.applies(to: date(2, 0), now: now, calendar: calendar))
    XCTAssertFalse(SettleGate.applies(to: date(8, 9, 41), now: now, calendar: calendar))
  }

  func testMidnightMovesSettleToTheNewDay() {
    let yesterday = date(1, 12)
    let justBefore = date(1, 23, 59)
    let justAfter = date(2, 0, 0)
    XCTAssertTrue(SettleGate.applies(to: yesterday, now: justBefore, calendar: calendar))
    XCTAssertFalse(SettleGate.applies(to: yesterday, now: justAfter, calendar: calendar))
    XCTAssertTrue(SettleGate.applies(to: date(2, 18), now: justAfter, calendar: calendar))
  }

  func testFollowsTheCalendarTimeZone() {
    // 07:30 UTC on 2 November is still 1 November (23:30 PST) in Los Angeles.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 7, minute: 30))!
    XCTAssertTrue(SettleGate.applies(to: date(1, 12), now: now, calendar: calendar))
    XCTAssertFalse(SettleGate.applies(to: date(1, 12), now: now, calendar: utc))
  }
}

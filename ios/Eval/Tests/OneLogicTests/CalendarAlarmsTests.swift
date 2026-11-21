import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Which alarms show on which Calendar day: the same rule as the Today timeline (AlarmPlan.fire), expanded over a range.
final class CalendarAlarmsTests: XCTestCase {
  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 1
    return c
  }()

  /// Saturday 2026-10-17 at the given time.
  private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  // The test dataset's alarms.
  private var specs: [AlarmSpec] {
    [
      AlarmSpec(hour: 6, minute: 30, label: "Wake up", weekdays: [2, 3, 4, 5, 6], isOn: true),
      AlarmSpec(hour: 8, minute: 30, label: "Weekend run", weekdays: [7, 1], isOn: false),
      AlarmSpec(hour: 13, minute: 0, label: "Take medicine", weekdays: [], isOn: true),
      AlarmSpec(hour: 22, minute: 30, label: "Wind down", weekdays: [1, 2, 3, 4, 5], isOn: true),
    ]
  }

  private func labels(_ rings: [AlarmOccurrence]) -> [String] {
    rings.map { specs[$0.index].label }
  }

  func testRepeatingAlarmsRingOnTheirWeekdays() {
    // Monday 2026-10-19, "now" is Saturday morning.
    let rings = CalendarAlarms.occurrences(of: specs, on: date(19), now: date(17, 9), calendar: cal)
    XCTAssertEqual(labels(rings), ["Wake up", "Wind down"])
    XCTAssertEqual(rings.map(\.date), [date(19, 6, 30), date(19, 22, 30)])
  }

  func testSaturdayHasNoWeekdayAlarms() {
    // Saturday: Wake up is weekdays only, Wind down is Sun-Thu... Weekend run is off. Only the one-time alarm remains.
    let rings = CalendarAlarms.occurrences(of: specs, on: date(17), now: date(17, 9), calendar: cal)
    XCTAssertEqual(labels(rings), ["Take medicine"])
  }

  func testOneTimeAlarmRingsOnTheDayOfItsNextOccurrence() {
    // Before 13:00 it rings today; after 13:00 it rings tomorrow, and not today any more.
    XCTAssertEqual(
      labels(
        CalendarAlarms.occurrences(of: specs, on: date(17), now: date(17, 12, 59), calendar: cal)),
      ["Take medicine"])
    XCTAssertEqual(
      labels(
        CalendarAlarms.occurrences(of: specs, on: date(17), now: date(17, 13, 1), calendar: cal)),
      [])
    XCTAssertEqual(
      labels(
        CalendarAlarms.occurrences(of: specs, on: date(18), now: date(17, 13, 1), calendar: cal)),
      ["Take medicine", "Wind down"], "Sunday: the one-time alarm and Wind down, in time order")
    XCTAssertEqual(
      labels(
        CalendarAlarms.occurrences(of: specs, on: date(19), now: date(17, 13, 1), calendar: cal)),
      ["Wake up", "Wind down"], "and not again on Monday")
  }

  func testOrderIsByTimeThenLabel() {
    let list = [
      AlarmSpec(hour: 7, minute: 0, label: "Zebra", weekdays: [2], isOn: true),
      AlarmSpec(hour: 7, minute: 0, label: "Apple", weekdays: [2], isOn: true),
      AlarmSpec(hour: 6, minute: 0, label: "", weekdays: [2], isOn: true),
    ]
    let rings = CalendarAlarms.occurrences(of: list, on: date(19), now: date(17), calendar: cal)
    XCTAssertEqual(rings.map(\.index), [2, 1, 0])
    XCTAssertEqual(CalendarAlarms.title(list[2].label), "Alarm", "no label reads Alarm")
  }

  func testRangeExpandsRepeatsAndPlacesTheOneTimeAlarmOnce() {
    // The week Sun 2026-10-18 ... Sat 2026-10-24, viewed on Saturday morning.
    let week = DateInterval(start: date(18), end: date(25))
    let rings = CalendarAlarms.occurrences(of: specs, in: week, now: date(17, 9), calendar: cal)
    let wake = rings.filter { specs[$0.index].label == "Wake up" }.map(\.date)
    XCTAssertEqual(
      wake, [date(19, 6, 30), date(20, 6, 30), date(21, 6, 30), date(22, 6, 30), date(23, 6, 30)])
    let wind = rings.filter { specs[$0.index].label == "Wind down" }.map(\.date)
    XCTAssertEqual(
      wind,
      [date(18, 22, 30), date(19, 22, 30), date(20, 22, 30), date(21, 22, 30), date(22, 22, 30)],
      "Sunday to Thursday")
    XCTAssertEqual(
      rings.filter { specs[$0.index].label == "Take medicine" }.count, 0,
      "its one ring is today (Saturday 13:00), outside this week")
    XCTAssertEqual(rings.map(\.date), rings.map(\.date).sorted(), "in time order")
  }

  func testRangeAgreesWithTheSingleDayRule() {
    let week = DateInterval(start: date(14), end: date(28))
    let now = date(17, 9)
    let range = CalendarAlarms.occurrences(of: specs, in: week, now: now, calendar: cal)
    var perDay: [AlarmOccurrence] = []
    for d in 14..<28 {
      perDay += CalendarAlarms.occurrences(of: specs, on: date(d), now: now, calendar: cal)
    }
    XCTAssertEqual(
      range, perDay.sorted { $0.date < $1.date || ($0.date == $1.date && $0.index < $1.index) })
  }
}

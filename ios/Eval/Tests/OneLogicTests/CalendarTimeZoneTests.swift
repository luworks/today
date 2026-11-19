import XCTest

@testable import TodayCore

final class CalendarTimeZoneTests: XCTestCase {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private var local: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  func testDefaultOffSelectionAddsCityOnceAndDisablePreservesIt() throws {
    let suite = "CalendarTimeZoneTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(defaults.bool(forKey: CalendarTimeZone.enabledKey))
    XCTAssertNil(CalendarTimeZone.selected(defaults))
    let city = CityRecord(id: 2_643_743, name: "London", tz: "Europe/London")
    defaults.set(["Asia/Tokyo"], forKey: CalendarTimeZone.worldCitiesKey)
    CalendarTimeZone.choose(city, defaults: defaults)
    CalendarTimeZone.choose(city, defaults: defaults)
    XCTAssertTrue(defaults.bool(forKey: CalendarTimeZone.enabledKey))
    XCTAssertEqual(CalendarTimeZone.selected(defaults), city)
    XCTAssertEqual(
      defaults.stringArray(forKey: CalendarTimeZone.worldCitiesKey), ["Asia/Tokyo", city.key])
    defaults.set(false, forKey: CalendarTimeZone.enabledKey)
    XCTAssertEqual(CalendarTimeZone.selected(defaults), city)
    XCTAssertEqual(
      defaults.stringArray(forKey: CalendarTimeZone.worldCitiesKey), ["Asia/Tokyo", city.key])
  }

  func testInvalidSelectionCannotEnableOrAddCity() throws {
    let suite = "CalendarTimeZoneTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    CalendarTimeZone.choose(CityRecord(id: 0, name: "Invalid", tz: "invalid"), defaults: defaults)
    XCTAssertFalse(defaults.bool(forKey: CalendarTimeZone.enabledKey))
    XCTAssertNil(CalendarTimeZone.selected(defaults))
    XCTAssertNil(CalendarTimeZone.city(stored: "garbled"))
  }

  func testFractionalOffsetAndNextDate() {
    let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
    XCTAssertEqual(
      CalendarTimeZone.label(at: date("2026-11-15T18:00:00Z"), zone: kathmandu, local: local),
      "23:45")
    XCTAssertEqual(
      CalendarTimeZone.label(at: date("2026-11-16T03:00:00Z"), zone: kathmandu, local: local),
      "08:45 +1")
    var tokyo = local
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    XCTAssertEqual(
      CalendarTimeZone.label(at: date("2026-11-16T03:00:00Z"), zone: local.timeZone, local: tokyo),
      "19:00 −1")
  }

  func testWorkingTimeUsesRemoteBoundariesAndNextDate() throws {
    let beijing = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    func visible(at utc: String) -> String? {
      CalendarTimeZone.workingTimeLabel(at: date(utc), zone: beijing, local: local)
    }
    XCTAssertNil(visible(at: "2026-11-18T23:59:59Z"))
    XCTAssertEqual(visible(at: "2026-11-19T00:00:00Z"), "08:00 +1")
    XCTAssertEqual(visible(at: "2026-11-19T11:59:59Z"), "19:59")
    XCTAssertNil(visible(at: "2026-11-19T12:00:00Z"))
  }

  func testWorkingHourIsEvaluatedForEachDayAcrossDST() throws {
    let beijing = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    XCTAssertEqual(
      CalendarTimeZone.workingHourLabel(
        4, day: date("2026-03-07T12:00:00Z"), zone: beijing, local: local), nil)
    XCTAssertEqual(
      CalendarTimeZone.workingHourLabel(
        4, day: date("2026-03-08T12:00:00Z"), zone: beijing, local: local), "19:00")
  }

  func testEachVisibleDayUsesItsOwnDSTOffset() {
    let london = TimeZone(identifier: "Europe/London")!
    XCTAssertEqual(
      CalendarTimeZone.hourLabel(9, day: date("2026-10-24T12:00:00Z"), zone: london, local: local),
      "17:00")
    XCTAssertEqual(
      CalendarTimeZone.hourLabel(9, day: date("2026-10-25T12:00:00Z"), zone: london, local: local),
      "16:00")
  }

  func testMissingAndRepeatedHoursStayUnambiguous() {
    let utc = TimeZone(secondsFromGMT: 0)!
    XCTAssertEqual(
      CalendarTimeZone.hourLabel(2, day: date("2026-03-08T12:00:00Z"), zone: utc, local: local), "—"
    )
    XCTAssertEqual(
      CalendarTimeZone.hourLabel(1, day: date("2026-11-01T12:00:00Z"), zone: utc, local: local),
      "08:00/09:00")
  }
}

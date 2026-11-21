import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class HealthLogicTests: XCTestCase {
  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  func testSleepBelongsToTheMorningYouWakeUp() {
    let now = date(16, 9)
    let nights = HealthMath.nights(
      [
        SleepInterval(start: date(15, 23, 10), end: date(16, 2), stage: .core),
        SleepInterval(start: date(16, 2), end: date(16, 2, 10), stage: .awake),
        SleepInterval(start: date(16, 2, 10), end: date(16, 6, 40), stage: .deep),
        SleepInterval(start: date(14, 0, 30), end: date(14, 7), stage: .unspecified),
      ], count: 7, now: now, calendar: cal)
    XCTAssertEqual(
      nights.map(\.day), [cal.startOfDay(for: date(14, 0)), cal.startOfDay(for: date(16, 0))])
    XCTAssertEqual(nights.last?.asleep, (2 * 60 + 50 + 4 * 60 + 30) * 60, "awake is not sleep")
    XCTAssertEqual(nights.last?.start, date(15, 23, 10))
    XCTAssertEqual(nights.last?.end, date(16, 6, 40))
  }

  func testStagedSleepDropsDuplicatePlainAsleep() {
    let now = date(16, 9)
    let nights = HealthMath.nights(
      [
        SleepInterval(start: date(15, 23), end: date(16, 7), stage: .unspecified),  // iPhone
        SleepInterval(start: date(15, 23), end: date(16, 3), stage: .core),  // Watch
        SleepInterval(start: date(16, 3), end: date(16, 7), stage: .rem),
      ], count: 7, now: now, calendar: cal)
    XCTAssertEqual(nights.count, 1)
    XCTAssertEqual(nights[0].asleep, 8 * 3600, "8 hours, not 16")
    XCTAssertEqual(nights[0].stages, [.rem, .core])
  }

  func testDuplicateStagedSourcesCountEachInstantOnlyOnce() {
    let sample = SleepInterval(start: date(15, 23), end: date(16, 7), stage: .core)
    let nights = HealthMath.nights([sample, sample], count: 7, now: date(16, 9), calendar: cal)
    XCTAssertEqual(nights.first?.asleep, 8 * 3600)
    XCTAssertEqual(nights.first?.total(.core), 8 * 3600)
  }

  func testPlainAsleepFillsOnlyUncoveredStagedGapsAndAwakeTakesPrecedence() {
    let intervals = [
      SleepInterval(start: date(15, 23), end: date(16, 3), stage: .core),
      SleepInterval(start: date(16, 3), end: date(16, 7), stage: .unspecified),
    ]
    let nights = HealthMath.nights(intervals, count: 7, now: date(16, 9), calendar: cal)
    XCTAssertEqual(
      nights.first?.asleep, 8 * 3600, "unstaged coverage must survive outside the staged interval")
    let awake = SleepInterval(start: date(16, 2), end: date(16, 2, 30), stage: .awake)
    let interrupted = HealthMath.nights(
      intervals + [awake], count: 7, now: date(16, 9), calendar: cal)
    XCTAssertEqual(interrupted.first?.asleep, 7.5 * 3600)
    XCTAssertEqual(interrupted.first?.total(.awake), 30 * 60)
  }
}

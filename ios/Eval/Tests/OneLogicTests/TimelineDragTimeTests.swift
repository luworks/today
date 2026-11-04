import Foundation
import Testing

@testable import TodayCore

struct TimelineDragTimeTests {
  let calendar = Calendar(identifier: .gregorian)
  var day: Date { Date(timeIntervalSince1970: 1_800_000_000) }

  @Test func fixedScaleAndAnchor() throws {
    let start = calendar.startOfDay(for: day).addingTimeInterval(11 * 3600 + 31 * 60)
    let drag = try #require(TimelineDragTime(original: start, day: day, calendar: calendar))
    #expect(drag.target(translation: 0) == start)
    #expect(
      drag.target(translation: 58) == calendar.startOfDay(for: day).addingTimeInterval(12 * 3600))
    #expect(drag.target(translation: .nan) == start)
  }

  @Test func fullDurationRemainsInDay() throws {
    let start = calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
    let drag = try #require(
      TimelineDragTime(original: start, day: day, duration: 3600, calendar: calendar))
    #expect(drag.target(translation: -10000) == calendar.startOfDay(for: day))
    #expect(
      drag.target(translation: 10000) == calendar.startOfDay(for: day).addingTimeInterval(23 * 3600)
    )
    #expect(TimelineDragTime(original: start, day: day, duration: 90000, calendar: calendar) == nil)
  }

  @Test func daylightSavingUsesActualDay() throws {
    var cal = calendar
    cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let date = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
    let drag = try #require(
      TimelineDragTime(original: date, day: date, duration: 3600, calendar: cal))
    #expect(drag.latest.timeIntervalSince(drag.earliest) == 24 * 3600)
  }
  @Test func aTimedReminderCannotAccidentallyBecomeDateOnlyAtMidnight() throws {
    let midnight = calendar.startOfDay(for: day)
    let original = midnight.addingTimeInterval(11 * 3600 + 31 * 60)
    let drag = try #require(
      TimelineDragTime(
        original: original, day: day, calendar: calendar,
        minimumStart: midnight.addingTimeInterval(60)))
    #expect(drag.target(translation: -10000) == midnight.addingTimeInterval(60))
    #expect(drag.target(translation: 58) == midnight.addingTimeInterval(12 * 3600))
    #expect(drag.duration == 0)
  }

  @Test func aSourceWindowNarrowsTheDayWithoutChangingItsMinuteGrid() throws {
    let midnight = calendar.startOfDay(for: day)
    let original = midnight.addingTimeInterval(11 * 3600 + 31 * 60)
    let lower = midnight.addingTimeInterval(10 * 3600 + 60)
    let upper = midnight.addingTimeInterval(14 * 3600 + 120)
    let drag = try #require(
      TimelineDragTime(
        original: original, day: day, calendar: calendar,
        minimumStart: lower, maximumStart: upper))
    #expect(drag.target(translation: -10000) == lower)
    #expect(drag.target(translation: 10000) == upper)
    #expect(drag.target(translation: 58) == midnight.addingTimeInterval(12 * 3600))
  }

}

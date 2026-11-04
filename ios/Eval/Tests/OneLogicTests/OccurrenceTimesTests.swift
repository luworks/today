import Foundation
import Testing

@testable import TodayCore

struct OccurrenceTimesTests {
  @Test func aMovedOccurrenceKeepsEarlierAndLaterSeriesTimes() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
    let anchor = day.addingTimeInterval(-86400 + 9 * 3600)
    let original = day.addingTimeInterval(9 * 3600)
    let moved = day.addingTimeInterval(15 * 3600)
    let overrides = OccurrenceTimes.moving([], from: original, to: moved)
    let starts = OccurrenceTimes.starts(
      start: anchor, duration: 1800, rule: .daily,
      overrides: overrides,
      in: DateInterval(start: day.addingTimeInterval(-86400), duration: 3 * 86400),
      calendar: calendar)
    #expect(starts == [anchor, moved, original.addingTimeInterval(86400)])
    let narrow = OccurrenceTimes.starts(
      start: anchor, duration: 1800, rule: .daily,
      overrides: overrides, in: DateInterval(start: moved, duration: 60), calendar: calendar)
    #expect(narrow == [moved])
    #expect(OccurrenceTimes.moving(overrides, from: moved, to: original).isEmpty)
    let again = OccurrenceTimes.moving(overrides, from: moved, to: moved.addingTimeInterval(300))
    #expect(again.count == 1 && again[0].original == original)
  }
}

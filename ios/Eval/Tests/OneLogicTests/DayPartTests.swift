import Foundation
import Testing

@testable import TodayCore

struct DayPartTests {
  struct Entry: Identifiable, Equatable {
    let id: String
    let hour: Int
    var planned = true
  }

  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
  var midnight: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }

  func at(_ hour: Int) -> Date { midnight.addingTimeInterval(TimeInterval(hour * 3600)) }

  func ids(_ entries: [Entry], closed: Set<DayPart> = [], keep: Set<String> = []) -> [String] {
    DayPart.rows(
      entries, day: midnight, calendar: calendar, start: { at($0.hour) }, isPlanned: \.planned,
      isOpen: { !closed.contains($0) }, keepsWhenClosed: { keep.contains($0.id) }
    ).map { row in
      switch row {
      case .label(let part, let count, let open): "label.\(part).\(count)\(open ? "" : ".closed")"
      case .item(let entry, let part): "\(entry.id)\(part.map { ".\($0)" } ?? "")"
      }
    }
  }

  @Test func hoursSplitAtNoonAndSix() {
    #expect(DayPart.of(at(11), day: midnight, calendar: calendar) == .morning)
    #expect(DayPart.of(at(12), day: midnight, calendar: calendar) == .afternoon)
    #expect(DayPart.of(at(17), day: midnight, calendar: calendar) == .afternoon)
    #expect(DayPart.of(at(18), day: midnight, calendar: calendar) == .evening)
    #expect(DayPart.of(at(-3), day: midnight, calendar: calendar) == .morning)
  }

  @Test func eachPartWithPlansIsOneCountedSection() {
    let rows = ids([
      Entry(id: "a", hour: 8), Entry(id: "b", hour: 9), Entry(id: "c", hour: 19),
    ])
    #expect(rows == ["label.morning.2", "a.morning", "b.morning", "label.evening.1", "c.evening"])
  }

  @Test func aPartWithOnlyFreeTimeHasNoSection() {
    let rows = ids([
      Entry(id: "a", hour: 8), Entry(id: "free", hour: 13, planned: false),
    ])
    #expect(rows == ["label.morning.1", "a.morning", "free"])
  }

  @Test func aClosedPartKeepsItsCountAndTimeContext() {
    let rows = ids(
      [
        Entry(id: "a", hour: 8), Entry(id: "free", hour: 9, planned: false),
        Entry(id: "now", hour: 10, planned: false), Entry(id: "b", hour: 14),
      ], closed: [.morning], keep: ["now", "free"])
    #expect(
      rows == [
        "label.morning.1.closed", "free.morning", "now.morning", "label.afternoon.1", "b.afternoon",
      ])
  }

  @Test func onTodayPartsThatEndedBeforeEntryStartClosed() {
    let entry = at(13)
    let open = DayPart.allCases.map {
      DayPartDisclosure().isOpen($0, day: midnight, entry: entry, calendar: calendar)
    }
    #expect(open == [false, true, true])
    let tomorrow = midnight.addingTimeInterval(86_400)
    #expect(
      DayPart.allCases.allSatisfy {
        DayPartDisclosure().isOpen($0, day: tomorrow, entry: entry, calendar: calendar)
      })
  }

  @Test func aTapOverridesTheDefaultForThatDayOnly() {
    var disclosure = DayPartDisclosure()
    disclosure.toggle(.morning, day: midnight, entry: at(13), calendar: calendar)
    disclosure.toggle(.evening, day: midnight, entry: at(13), calendar: calendar)
    #expect(disclosure.isOpen(.morning, day: midnight, entry: at(13), calendar: calendar))
    #expect(!disclosure.isOpen(.evening, day: midnight, entry: at(13), calendar: calendar))
    let tomorrow = midnight.addingTimeInterval(86_400)
    disclosure.toggle(.afternoon, day: tomorrow, entry: at(13), calendar: calendar)
    #expect(disclosure.isOpen(.evening, day: tomorrow, entry: at(13), calendar: calendar))
    #expect(!disclosure.isOpen(.afternoon, day: tomorrow, entry: at(13), calendar: calendar))
    #expect(disclosure.isOpen(.morning, day: midnight, entry: at(13), calendar: calendar))
    #expect(!disclosure.isOpen(.evening, day: midnight, entry: at(13), calendar: calendar))
  }

  @Test func defaultsChangeAtLocalNoonOnADaylightSavingTransition() throws {
    var local = calendar
    local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let noon = try #require(
      local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
    let disclosure = DayPartDisclosure()
    #expect(
      disclosure.isOpen(.morning, day: noon, entry: noon.addingTimeInterval(-60), calendar: local))
    #expect(!disclosure.isOpen(.morning, day: noon, entry: noon, calendar: local))
    #expect(disclosure.isOpen(.afternoon, day: noon, entry: noon, calendar: local))
  }
}

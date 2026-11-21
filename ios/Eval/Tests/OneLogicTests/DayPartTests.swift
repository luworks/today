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

  func ids(_ entries: [Entry]) -> [String] {
    DayPart.rows(
      entries, day: midnight, calendar: calendar, start: { at($0.hour) }, isPlanned: \.planned
    ).map { row in
      switch row {
      case .label(let part): "label.\(part)"
      case .item(let entry, let card, let closes):
        "\(entry.id)\(card.map { ".\($0)" } ?? "")\(closes ? ".close" : "")"
      case .cardEnd(let part): "end.\(part)"
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

  @Test func eachPartWithPlansIsOneLabelledCard() {
    let rows = ids([
      Entry(id: "a", hour: 8), Entry(id: "b", hour: 9), Entry(id: "c", hour: 19),
    ])
    #expect(
      rows == [
        "label.morning", "a.morning", "b.morning.close", "end.morning",
        "label.evening", "c.evening.close", "end.evening",
      ])
  }

  @Test func aPartWithOnlyFreeTimeHasNoCard() {
    let rows = ids([
      Entry(id: "a", hour: 8), Entry(id: "free", hour: 13, planned: false),
    ])
    #expect(rows == ["label.morning", "a.morning.close", "end.morning", "free"])
  }

  @Test func noItemsNoRows() {
    #expect(ids([]).isEmpty)
  }
}

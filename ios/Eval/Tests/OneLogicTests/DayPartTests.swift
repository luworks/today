import XCTest

@testable import TodayCore

final class DayPartTests: XCTestCase {
  private struct Row: Identifiable, Equatable {
    let id: String
    let start: Date
    var planned = true
  }

  private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  private func at(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
    cal.date(
      from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  private func part(_ hour: Int, _ minute: Int = 0) -> DayPart {
    DayPart.of(at(hour, minute), day: at(0), calendar: cal)
  }

  /// "[part]" is a label, "[/part]" a card end, a name a carded row ("name." the card's last) and "~name" a loose one.
  private func layout(_ rows: [Row]) -> [String] {
    DayPart.rows(
      rows, day: at(0), calendar: cal, start: \.start, isPlanned: \.planned
    ).map {
      switch $0 {
      case .label(let part): "[\(part)]"
      case .item(let row, let card, let closesCard):
        (card == nil ? "~" : "") + row.id + (closesCard ? "." : "")
      case .emptyPart(let part): "empty:\(part.rawValue)"
      case .cardEnd(let part): "[/\(part)]"
      }
    }
  }

  func testBoundaries() {
    XCTAssertEqual(part(0), .morning)
    XCTAssertEqual(part(11, 59), .morning)
    XCTAssertEqual(part(12), .afternoon)
    XCTAssertEqual(part(17, 59), .afternoon)
    XCTAssertEqual(part(18), .evening)
    XCTAssertEqual(part(23, 59), .evening)
  }

  func testChosenBoundariesMoveTheParts() {
    let early = DayPart.Boundaries(afternoon: 11, evening: 17)
    func moved(_ hour: Int, _ minute: Int = 0) -> DayPart {
      DayPart.of(at(hour, minute), day: at(0), calendar: cal, boundaries: early)
    }
    XCTAssertEqual(moved(10, 59), .morning)
    XCTAssertEqual(moved(11), .afternoon)
    XCTAssertEqual(moved(16, 59), .afternoon)
    XCTAssertEqual(moved(17), .evening)
  }

  func testBoundariesThatBreakTheOrderAreTheStandardOnes() {
    let standard = DayPart.Boundaries.standard
    XCTAssertEqual(standard.afternoon, 12)
    XCTAssertEqual(standard.evening, 18)
    XCTAssertEqual(DayPart.Boundaries(afternoon: 18, evening: 12), standard)
    XCTAssertEqual(DayPart.Boundaries(afternoon: 14, evening: 14), standard)
    XCTAssertEqual(DayPart.Boundaries(afternoon: 0, evening: 18), standard, "morning needs an hour")
    XCTAssertEqual(DayPart.Boundaries(afternoon: 12, evening: 24), standard)
    XCTAssertEqual(DayPart.Boundaries(afternoon: 1, evening: 23).afternoon, 1)
  }

  func testChoicesKeepThePartsInOrder() {
    let b = DayPart.Boundaries(afternoon: 13, evening: 15)
    XCTAssertEqual(b.afternoonChoices.last, 14)
    XCTAssertEqual(b.afternoonChoices.first, 1)
    XCTAssertEqual(b.eveningChoices.first, 14)
    XCTAssertEqual(b.eveningChoices.last, 23)
  }

  func testAnEventStaysInThePartItStarts() {
    XCTAssertEqual(part(11, 30), .morning, "11:30 to 13:00 is a morning event")
  }

  func testAnEventFromAnEarlierDayOpensTheMorning() {
    XCTAssertEqual(DayPart.of(at(23, day: 15), day: at(0), calendar: cal), .morning)
    XCTAssertEqual(
      layout([Row(id: "overnight", start: at(23, day: 15)), Row(id: "a", start: at(8))]),
      ["[morning]", "overnight", "a.", "[/morning]"])
  }

  func testEmptyPartsShowNothing() {
    XCTAssertEqual(
      layout([Row(id: "a", start: at(9)), Row(id: "b", start: at(20))]),
      ["[morning]", "a.", "[/morning]", "[evening]", "b.", "[/evening]"])
    XCTAssertEqual(layout([]), [])
  }

  func testADragShowsEmptyPartsAsTargets() {
    let rows = DayPart.rows(
      [Row(id: "a", start: at(9))], day: at(0), calendar: cal, start: \.start,
      isPlanned: \.planned, showsEmptyParts: true)
    XCTAssertEqual(rows.count, 9, "Three parts of label, row or target, and end")
    guard case .emptyPart(.afternoon) = rows[4] else { return XCTFail("\(rows[4])") }
  }

  func testPartBoundsAndUsualTimes() {
    XCTAssertEqual(DayPart.afternoon.bounds(day: at(0), calendar: cal)?.start, at(12))
    XCTAssertEqual(DayPart.afternoon.bounds(day: at(0), calendar: cal)?.end, at(18))
    XCTAssertEqual(DayPart.evening.usualTime(day: at(0), calendar: cal), at(19))
  }

  func testNowSitsInsideACardThatHasItems() {
    XCTAssertEqual(
      layout([
        Row(id: "a", start: at(9)), Row(id: "now", start: at(10), planned: false),
        Row(id: "b", start: at(11)),
      ]), ["[morning]", "a", "now", "b.", "[/morning]"])
  }

  func testNowInAnEmptyPartStaysLooseBetweenCards() {
    XCTAssertEqual(
      layout([
        Row(id: "a", start: at(9)), Row(id: "now", start: at(14), planned: false),
        Row(id: "b", start: at(19)),
      ]), ["[morning]", "a.", "[/morning]", "~now", "[evening]", "b.", "[/evening]"])
  }

  func testFreeTimeAloneNeverEarnsACard() {
    XCTAssertEqual(
      layout([
        Row(id: "a", start: at(9)), Row(id: "now", start: at(13), planned: false),
        Row(id: "free", start: at(13), planned: false),
      ]), ["[morning]", "a.", "[/morning]", "~now", "~free"])
  }

  func testOnlyLooseRowsMakeNoCardAtAll() {
    XCTAssertEqual(layout([Row(id: "now", start: at(9), planned: false)]), ["~now"])
  }

  func testOrderWithinAPartIsKept() {
    XCTAssertEqual(
      layout([Row(id: "b", start: at(9)), Row(id: "a", start: at(9))]),
      ["[morning]", "b", "a.", "[/morning]"])
  }

  func testIdentityFollowsTheItemAcrossParts() {
    let id = DayPart.rows(
      [Row(id: "a", start: at(9))], day: at(0), calendar: cal, start: \.start, isPlanned: \.planned
    )[1].id
    let moved = DayPart.rows(
      [Row(id: "a", start: at(19))], day: at(0), calendar: cal, start: \.start,
      isPlanned: \.planned
    )[1].id
    XCTAssertEqual(id, moved)
  }
}

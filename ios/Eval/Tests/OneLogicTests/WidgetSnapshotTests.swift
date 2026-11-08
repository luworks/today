import XCTest

@testable import TodayShared

/// The widgets' "next three things today": selection, order, tomorrow fallback, timeline dates, JSON round trip.
final class WidgetSnapshotTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  func date(_ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: min))!
  }
  /// Friday 2026-10-16, 09:41
  lazy var now = date(16, 9, 41)

  func item(
    _ title: String, _ start: Date, end: Date? = nil, allDay: Bool = false,
    kind: WidgetItem.Kind = .event
  ) -> WidgetItem {
    WidgetItem(id: title, title: title, start: start, end: end, isAllDay: allDay, kind: kind)
  }

  func testNextThreeMergedAndSortedByTime() {
    let items = [
      item("Dentist", date(16, 15), end: date(16, 16)),
      item("Call Alex", date(16, 11), kind: .reminder),
      item("Gym", date(16, 18), kind: .alarm),
      item("Standup", date(16, 10), end: date(16, 10, 15)),
      item("Late", date(16, 21), kind: .reminder),
    ]
    let next = NextItems.select(from: items, now: now, calendar: cal)
    XCTAssertEqual(next.today.map(\.title), ["Standup", "Call Alex", "Dentist"])
    XCTAssertEqual(next.remainingToday, 5)
    XCTAssertNil(next.tomorrow)
  }

  func testPastItemsDropOutButEventsInProgressStay() {
    let items = [
      item("Breakfast reminder", date(16, 8), kind: .reminder),
      item("Wake up", date(16, 7), kind: .alarm),
      item("Long meeting", date(16, 9), end: date(16, 10)),
      item("Finished meeting", date(16, 8), end: date(16, 9)),
      item("Lunch", date(16, 12)),
    ]
    let next = NextItems.select(from: items, now: now, calendar: cal)
    XCTAssertEqual(next.today.map(\.title), ["Long meeting", "Lunch"])
    XCTAssertEqual(next.remainingToday, 2)
  }

  /// The timeline redraws exactly at each start and end; those entries must advance the list.
  func testItemsLeaveAtTheirTimelineEntry() {
    let items = [
      item("Call Alex", date(16, 11), kind: .reminder),
      item("Dentist", date(16, 15), end: date(16, 16)),
    ]
    XCTAssertEqual(
      NextItems.select(from: items, now: date(16, 11), calendar: cal).today.map(\.title),
      ["Dentist"])
    XCTAssertEqual(
      NextItems.select(from: items, now: date(16, 15), calendar: cal).today.map(\.title),
      ["Dentist"])
    XCTAssertTrue(NextItems.select(from: items, now: date(16, 16), calendar: cal).today.isEmpty)
  }

  func testAllDayFirstAndStaysAllDay() {
    let items = [
      item("Lunch", date(16, 12)),
      item("Holiday", date(16), allDay: true),
    ]
    let late = date(16, 23, 30)
    XCTAssertEqual(
      NextItems.select(from: items, now: now, calendar: cal).today.map(\.title),
      ["Holiday", "Lunch"])
    XCTAssertEqual(
      NextItems.select(from: items, now: late, calendar: cal).today.map(\.title), ["Holiday"])
  }

  func testOtherDaysAreNotToday() {
    let items = [item("Yesterday", date(15, 15)), item("Tomorrow", date(17, 9))]
    let next = NextItems.select(from: items, now: now, calendar: cal)
    XCTAssertTrue(next.today.isEmpty)
    XCTAssertEqual(next.remainingToday, 0)
    XCTAssertEqual(next.tomorrow?.title, "Tomorrow")
  }

  func testTomorrowOnlyWhenNothingLeftToday() {
    let items = [item("Tonight", date(16, 20), kind: .reminder), item("Tomorrow", date(17, 9))]
    XCTAssertNil(NextItems.select(from: items, now: now, calendar: cal).tomorrow)
    let next = NextItems.select(from: items, now: date(16, 20, 30), calendar: cal)
    XCTAssertTrue(next.today.isEmpty)
    XCTAssertEqual(next.tomorrow?.title, "Tomorrow")
  }

  func testTomorrowPicksFirstInAppleOrder() {
    let items = [
      item("Early", date(17, 7)), item("Trip", date(17), allDay: true), item("Later", date(17, 11)),
    ]
    XCTAssertEqual(
      NextItems.select(from: items, now: date(16, 22), calendar: cal).tomorrow?.title, "Trip")
  }

  func testNothingAtAll() {
    let next = NextItems.select(from: [], now: now, calendar: cal)
    XCTAssertEqual(next, NextUp(today: [], remainingToday: 0, tomorrow: nil))
  }

  func testLimit() {
    let items = (10...15).map { item("T\($0)", date(16, $0)) }
    let next = NextItems.select(from: items, now: now, calendar: cal, limit: 1)
    XCTAssertEqual(next.today.map(\.title), ["T10"])
    XCTAssertEqual(next.remainingToday, 6)
  }

  func testTimelineDatesAdvanceAtEachStartAndEndUntilMidnight() {
    let items = [
      item("Standup", date(16, 10), end: date(16, 10, 15)),
      item("Past", date(16, 8), kind: .reminder),
      item("Holiday", date(16), allDay: true),
      item("Tomorrow", date(17, 9)),
    ]
    XCTAssertEqual(
      NextItems.timelineDates(for: items, now: now, calendar: cal),
      [now, date(16, 10), date(16, 10, 15), date(17)])
  }

  func testDeepLinks() {
    let url = WidgetLink.url(day: date(17, 9), calendar: cal)
    XCTAssertEqual(url.absoluteString, "today://today?day=2026-10-17")
    XCTAssertEqual(WidgetLink.day(from: url, now: now, calendar: cal), date(17))
    XCTAssertEqual(WidgetLink.day(from: WidgetLink.url(), now: now, calendar: cal), date(16))
    XCTAssertEqual(
      WidgetLink.day(from: URL(string: "today://today?day=bad")!, now: now, calendar: cal), date(16)
    )
    XCTAssertNil(WidgetLink.day(from: URL(string: "https://example.com")!, now: now, calendar: cal))
  }

  func testSnapshotRoundTrip() throws {
    let snap = WidgetSnapshot(
      generatedAt: date(16, 9),
      items: [
        item("Dentist", date(16, 15), end: date(16, 16)),
        item("Holiday", date(16), allDay: true),
        item("Gym", date(16, 18), kind: .alarm),
      ])
    XCTAssertEqual(WidgetSnapshot.decode(try snap.encoded()), snap)
    XCTAssertNil(WidgetSnapshot.decode(Data("nope".utf8)))
  }

  // MARK: Live Apple Calendar merge

  func testMergeReplacesAppleCalendarEventsWithLiveOnes() {
    let snapshot = [
      WidgetItem(
        id: "old", title: "Moved meeting", start: date(16, 10), end: date(16, 11), kind: .event,
        externalID: "ek1"),
      WidgetItem(
        id: "mirror", title: "Lunch (mirrored)", start: date(16, 12), end: date(16, 13),
        kind: .event, externalID: "ek2"),
      WidgetItem(
        id: "local", title: "Today-only event", start: date(16, 14), end: date(16, 15), kind: .event
      ),
      item("Call Alex", date(16, 11), kind: .reminder),
      item("Gym", date(16, 18), kind: .alarm),
    ]
    let live = [
      WidgetItem(
        id: "new1", title: "Moved meeting", start: date(16, 16), end: date(16, 17), kind: .event,
        externalID: "ek1"),
      WidgetItem(
        id: "new2", title: "Lunch (mirrored)", start: date(16, 12), end: date(16, 13), kind: .event,
        externalID: "ek2"),
      WidgetItem(
        id: "new3", title: "Added in Apple Calendar", start: date(16, 15), end: date(16, 16),
        kind: .event, externalID: "ek3"),
    ]
    let merged = NextItems.merge(snapshot: snapshot, live: live)
    XCTAssertEqual(
      merged.map(\.title),
      [
        "Call Alex", "Lunch (mirrored)", "Today-only event", "Added in Apple Calendar",
        "Moved meeting", "Gym",
      ])
    XCTAssertEqual(
      merged.filter { $0.title == "Lunch (mirrored)" }.count, 1, "a mirrored event shows once")
  }

  // MARK: Settled

  private func next(_ items: [WidgetItem]) -> LockScreenNext {
    LockScreenNext.make(items: items, now: now, calendar: cal) { _ in "time" }
  }

  private func event(_ id: String, _ start: Date, _ end: Date) -> WidgetItem {
    WidgetItem(id: id, title: id, start: start, end: end, kind: .event, externalID: "ek-" + id)
  }

  func testASettledItemLeavesTheSnapshotAndTheNextMovesUp() {
    let items = [
      item("a", date(16, 10)), item("b", date(16, 11), kind: .reminder),
      item("c", date(16, 12), kind: .alarm), item("d", date(16, 13)),
    ]
    let shown = NextItems.removingSettled(items, settledIDs: ["a"])
    XCTAssertEqual(shown.items.map(\.title), ["b", "c", "d"])
    XCTAssertEqual(shown.settledEvents, [], "only Apple Calendar events need a key")
    XCTAssertEqual(
      NextItems.select(from: shown.items, now: now, calendar: cal).today.map(\.title),
      ["b", "c", "d"])
    XCTAssertEqual(
      NextItems.select(from: shown.items, now: now, calendar: cal).remainingToday, 3)
  }

  func testASettledNowRowIsGoneAndTheNextItemLeads() {
    let items = [event("church", date(16, 9), date(16, 14, 50)), item("b", date(16, 15))]
    XCTAssertEqual(next(items).headline, "Now", "the row the owner saw")
    let shown = NextItems.removingSettled(items, settledIDs: ["church"]).items
    XCTAssertEqual(next(shown).title, "b")
    XCTAssertEqual(next(shown).headline, "time")
  }

  func testPlusCountLeavesOutSettled() {
    let items = [
      event("church", date(16, 9), date(16, 14, 50)), item("a", date(16, 15)),
      item("b", date(16, 16)), item("c", date(16, 17)),
    ]
    XCTAssertEqual(next(items).more, "+3")
    let shown = NextItems.removingSettled(items, settledIDs: ["church", "b"]).items
    XCTAssertEqual(next(shown).title, "a")
    XCTAssertEqual(next(shown).more, "+1")
  }

  func testAllSettledLeavesNothingToday() {
    let items = [item("a", date(16, 10))]
    let shown = NextItems.removingSettled(items, settledIDs: ["a"]).items
    XCTAssertTrue(next(shown).isEmpty)
    XCTAssertEqual(NextItems.select(from: shown, now: now, calendar: cal).remainingToday, 0)
  }

  func testTheLiveCopyOfASettledEventStaysOff() {
    let church = event("church", date(16, 9), date(16, 14, 50))
    let tomorrow = event("church", date(17, 9), date(17, 14, 50))
    let other = event("other", date(16, 15), date(16, 16))
    let shown = NextItems.removingSettled([church, other], settledIDs: ["church"])
    let merged = NextItems.merge(
      snapshot: shown.items, live: [church, tomorrow, other], settledEvents: shown.settledEvents)
    XCTAssertEqual(merged.map(\.start), [other.start, tomorrow.start], "only that occurrence")
    XCTAssertEqual(next(merged).title, "other")
    XCTAssertNil(next(merged).more)
  }

  func testSettledEventsSurviveTheSnapshotRoundTripAndOldSnapshotsDecode() throws {
    let snapshot = WidgetSnapshot(generatedAt: now, items: [], settledEvents: ["ek@1"])
    XCTAssertEqual(
      WidgetSnapshot.decode(try snapshot.encoded())?.settledEvents, ["ek@1"])
    let old = try JSONSerialization.data(withJSONObject: [
      "generatedAt": ISO8601DateFormatter().string(from: now), "items": [],
    ])
    XCTAssertNil(try XCTUnwrap(WidgetSnapshot.decode(old)).settledEvents)
  }

  func testMergeWithoutLiveKeepsSnapshot() {
    let snapshot = [
      WidgetItem(id: "x", title: "Meeting", start: date(16, 10), kind: .event, externalID: "ek1")
    ]
    XCTAssertEqual(NextItems.merge(snapshot: snapshot, live: nil), snapshot)
    // Live but empty: the event was deleted in Apple Calendar.
    XCTAssertTrue(NextItems.merge(snapshot: snapshot, live: []).isEmpty)
  }

  func testEventRowsClipMultiDayEventsToEachDay() {
    let days = [date(16), date(17), date(18)]
    // Fri 22:00 → Sun 02:00: a late part on Friday, all of Saturday, an early part on Sunday.
    let rows = WidgetItem.eventRows(
      id: "trip", title: "Trip", start: date(16, 22), end: date(18, 2), isAllDay: false,
      externalID: "ek", days: days, calendar: cal)
    XCTAssertEqual(rows.map(\.start), [date(16, 22), date(17), date(18)])
    XCTAssertEqual(rows.map(\.end), [date(17), nil, date(18, 2)])
    XCTAssertEqual(rows.map(\.isAllDay), [false, true, false])
    XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    XCTAssertTrue(rows.allSatisfy { $0.externalID == "ek" && $0.kind == .event })
  }

  func testEventRowsAllDayAndOutsideTheWindow() {
    let days = [date(16), date(17), date(18)]
    let holiday = WidgetItem.eventRows(
      id: "h", title: "Holiday", start: date(17), end: date(18), isAllDay: true,
      externalID: nil, days: days, calendar: cal)
    XCTAssertEqual(holiday.map(\.start), [date(17)])
    XCTAssertEqual(holiday.first?.isAllDay, true)
    XCTAssertTrue(
      WidgetItem.eventRows(
        id: "p", title: "Past", start: date(15, 9), end: date(15, 10), isAllDay: false,
        externalID: nil, days: days, calendar: cal
      ).isEmpty)
    // An event ending exactly at midnight belongs only to its own day.
    let late = WidgetItem.eventRows(
      id: "l", title: "Late", start: date(16, 23), end: date(17), isAllDay: false,
      externalID: nil, days: days, calendar: cal)
    XCTAssertEqual(late.map(\.start), [date(16, 23)])
  }

  /// Just after midnight, today's list and the Tomorrow line both come from the snapshot written the day before.
  func testThreeDaySnapshotCoversTheMidnightRollover() {
    let written = [item("Sat run", date(17, 8), kind: .alarm), item("Sun brunch", date(18, 11))]
    let afterMidnight = date(17, 0, 5)
    XCTAssertEqual(
      NextItems.select(from: written, now: afterMidnight, calendar: cal).today.map(\.title),
      ["Sat run"])
    XCTAssertEqual(
      NextItems.select(from: written, now: date(17, 9), calendar: cal).tomorrow?.title, "Sun brunch"
    )
    XCTAssertEqual(WidgetSnapshot.days, 3)
  }

  func testTimelineRunsThroughTomorrowWhenAsked() {
    let items = [
      item("Standup", date(16, 10), end: date(16, 10, 15)),
      item("Tomorrow", date(17, 9), end: date(17, 10)),
      item("Later", date(18, 9)),
    ]
    XCTAssertEqual(
      NextItems.timelineDates(for: items, now: now, days: 2, calendar: cal),
      [now, date(16, 10), date(16, 10, 15), date(17), date(17, 9), date(17, 10), date(18)])
  }

  func testReloadHourlyButNeverAfterMidnight() {
    XCTAssertEqual(NextItems.reloadDate(now: now, calendar: cal), now.addingTimeInterval(3600))
    XCTAssertEqual(NextItems.reloadDate(now: date(16, 23, 30), calendar: cal), date(17))
  }

  func testSnapshotCarriesCalendarSettingsAndOldSnapshotsStillDecode() throws {
    let snap = WidgetSnapshot(
      generatedAt: date(16, 9),
      items: [
        WidgetItem(id: "m", title: "Meeting", start: date(16, 10), kind: .event, externalID: "ek1")
      ],
      calendar: .init(isOn: true, hiddenCalendarIDs: ["work"]))
    XCTAssertEqual(WidgetSnapshot.decode(try snap.encoded()), snap)
    let old =
      #"{"generatedAt":"2026-10-16T16:00:00Z","items":[{"id":"a","isAllDay":false,"kind":"alarm","start":"2026-10-16T17:00:00Z","title":"Gym"}]}"#
    let decoded = try XCTUnwrap(WidgetSnapshot.decode(Data(old.utf8)))
    XCTAssertNil(decoded.calendar)
    XCTAssertNil(decoded.items.first?.externalID)
  }
}

import XCTest

@testable import TodayShared

/// Travel time: who gets an estimate (and so any network request), cache keys, refresh, leave-by, labels,
/// and that the widget keeps the app's estimate when it swaps in live Apple Calendar events.
final class TravelTimeTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  func date(_ d: Int, _ h: Int = 0, _ min: Int = 0, _ sec: Int = 0) -> Date {
    cal.date(
      from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: min, second: sec))!
  }
  /// Friday 2026-10-16, 09:41
  lazy var now = date(16, 9, 41)
  let hhmm: (Date) -> String = { d in
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let x = c.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", x.hour!, x.minute!)
  }

  // MARK: Eligibility

  func testOnlyUpcomingTimedEventsTodayOrTomorrowWithAPlace() {
    let place = "1 Infinite Loop, Cupertino"
    XCTAssertTrue(
      TravelTime.isEligible(
        start: date(16, 14), isAllDay: false, location: place, now: now, calendar: cal))
    XCTAssertTrue(
      TravelTime.isEligible(
        start: date(17, 23, 59), isAllDay: false, location: place, now: now, calendar: cal))
    XCTAssertFalse(
      TravelTime.isEligible(
        start: date(18, 0, 0), isAllDay: false, location: place, now: now, calendar: cal),
      "day after tomorrow")
    XCTAssertFalse(
      TravelTime.isEligible(
        start: date(16, 9), isAllDay: false, location: place, now: now, calendar: cal),
      "already started")
    XCTAssertFalse(
      TravelTime.isEligible(start: now, isAllDay: false, location: place, now: now, calendar: cal),
      "starting now")
    XCTAssertFalse(
      TravelTime.isEligible(
        start: date(17), isAllDay: true, location: place, now: now, calendar: cal), "all-day")
  }

  func testNoLocationMeansNoLookup() {
    for loc in ["", "   ", "\n"] {
      XCTAssertFalse(
        TravelTime.isEligible(
          start: date(16, 14), isAllDay: false, location: loc, now: now, calendar: cal))
    }
  }

  func testVideoCallsAreNotPlaces() {
    for loc in [
      "Zoom", "Microsoft Teams Meeting", "https://zoom.us/j/123", "meet.google.com/abc-defg-hij",
      "FaceTime", "Online",
    ] {
      XCTAssertFalse(TravelTime.isPhysical(loc), loc)
    }
    for loc in ["Blue Bottle Coffee", "Apple Park", "300 Post St, San Francisco", "Zoo"] {
      XCTAssertTrue(TravelTime.isPhysical(loc), loc)
    }
  }

  // MARK: Cache

  func testCacheKeyPerEventDayAndAddress() {
    let a = TravelTime.cacheKey(
      eventID: "E1", start: date(16, 14), address: "Apple Park", calendar: cal)
    XCTAssertEqual(a, "E1|2026-10-16|apple park")
    XCTAssertEqual(
      a,
      TravelTime.cacheKey(
        eventID: "E1", start: date(16, 18), address: " apple park ", calendar: cal),
      "same day, same place")
    XCTAssertNotEqual(
      a,
      TravelTime.cacheKey(eventID: "E1", start: date(17, 14), address: "Apple Park", calendar: cal),
      "repeating event, next day")
    XCTAssertNotEqual(
      a, TravelTime.cacheKey(eventID: "E1", start: date(16, 14), address: "SFO", calendar: cal),
      "location edited")
    XCTAssertNotEqual(
      a,
      TravelTime.cacheKey(eventID: "E2", start: date(16, 14), address: "Apple Park", calendar: cal))
    XCTAssertEqual(TravelTime.day(ofKey: a), "2026-10-16")
  }

  func testRefreshAtMostEveryFifteenMinutes() {
    XCTAssertTrue(TravelTime.needsRefresh(nil, now: now))
    let fresh = TravelEstimate(seconds: 900, computedAt: now.addingTimeInterval(-14 * 60 - 59))
    XCTAssertFalse(TravelTime.needsRefresh(fresh, now: now))
    let stale = TravelEstimate(seconds: 900, computedAt: now.addingTimeInterval(-15 * 60))
    XCTAssertTrue(TravelTime.needsRefresh(stale, now: now))
    // A failed lookup is cached too, so it isn't retried on every redraw.
    let failed = TravelEstimate(seconds: nil, computedAt: now.addingTimeInterval(-60))
    XCTAssertFalse(TravelTime.needsRefresh(failed, now: now))
    XCTAssertNil(TravelTime.usable(failed))
  }

  func testUsableRange() {
    XCTAssertNil(TravelTime.usable(nil))
    XCTAssertNil(TravelTime.usable(TravelEstimate(seconds: 30, computedAt: now)), "already there")
    XCTAssertNil(
      TravelTime.usable(TravelEstimate(seconds: 6 * 3600, computedAt: now)),
      "probably the wrong place")
    XCTAssertEqual(TravelTime.usable(TravelEstimate(seconds: 1080, computedAt: now)), 1080)
  }

  func testPruneDropsPastDays() {
    let cache = [
      "A|2026-10-15|x": TravelEstimate(seconds: 60, computedAt: now),
      "B|2026-10-16|x": TravelEstimate(seconds: 60, computedAt: now),
      "C|2026-10-17|x": TravelEstimate(seconds: 60, computedAt: now),
      "garbage": TravelEstimate(seconds: 60, computedAt: now),
    ]
    XCTAssertEqual(
      Set(TravelTime.pruned(cache, now: now, calendar: cal).keys),
      ["B|2026-10-16|x", "C|2026-10-17|x"])
  }

  // MARK: Leave by

  func testLeaveByRoundsDownToTheMinute() {
    XCTAssertEqual(
      TravelTime.leaveBy(start: date(16, 14, 38), travelSeconds: 18 * 60), date(16, 14, 20))
    XCTAssertEqual(
      TravelTime.leaveBy(start: date(16, 14, 38), travelSeconds: 18 * 60 + 10), date(16, 14, 19),
      "never later than needed")
    XCTAssertEqual(TravelTime.minutes(18 * 60 + 10), 19)
    XCTAssertEqual(TravelTime.minutes(5), 1)
  }

  func testLabels() {
    XCTAssertEqual(TravelTime.durationText(seconds: 18 * 60), "18 min")
    XCTAssertEqual(TravelTime.durationText(seconds: 3600), "1 h")
    XCTAssertEqual(TravelTime.durationText(seconds: 65 * 60), "1 h 5 min")
    XCTAssertEqual(
      TravelTime.label(start: date(16, 14, 38), travelSeconds: 18 * 60, now: now, time: hhmm),
      "Drive 18 min · Leave by 14:20")
    XCTAssertEqual(
      TravelTime.label(start: date(16, 10), travelSeconds: 25 * 60, now: now, time: hhmm),
      "Drive 25 min · Leave now")
  }

  // MARK: Permission and throttling

  func testSoonestRequestsFirstAndAFewAtATime() {
    let c: [(id: String, start: Date)] = [
      ("c", date(17, 9)), ("a", date(16, 11)), ("d", date(17, 12)), ("b", date(16, 15)),
    ]
    XCTAssertEqual(TravelTime.nextRequests(c, inFlight: 0), ["a", "b", "c"])
    XCTAssertEqual(TravelTime.nextRequests(c, inFlight: 2), ["a"])
    XCTAssertEqual(TravelTime.nextRequests(c, inFlight: 3), [])
  }

  // MARK: Widget

  func testWidgetKeepsTravelWhenLiveEventsReplaceTheSnapshot() {
    let start = date(16, 14, 38)
    let fromApp = WidgetItem(
      id: "snap", title: "Dentist", start: start, end: date(16, 15, 30), kind: .event,
      externalID: "EK1",
      travelMinutes: 18, leaveBy: date(16, 14, 20))
    let live = WidgetItem(
      id: "EK1@x#y", title: "Dentist", start: start, end: date(16, 15, 30), kind: .event,
      externalID: "EK1")
    let moved = WidgetItem(
      id: "EK2@x#y", title: "Lunch", start: date(16, 12), end: date(16, 13), kind: .event,
      externalID: "EK2")
    let merged = NextItems.merge(snapshot: [fromApp], live: [moved, live])
    XCTAssertEqual(merged.map(\.title), ["Lunch", "Dentist"])
    XCTAssertEqual(merged.last?.travelMinutes, 18)
    XCTAssertEqual(merged.last?.leaveBy, date(16, 14, 20))
    XCTAssertNil(merged.first?.leaveBy)

    // Moved in Apple Calendar since the app's estimate: the old leave-by no longer applies.
    let rescheduled = WidgetItem(
      id: "EK1@z", title: "Dentist", start: date(16, 16), end: date(16, 17), kind: .event,
      externalID: "EK1")
    XCTAssertNil(NextItems.merge(snapshot: [fromApp], live: [rescheduled]).first?.leaveBy)
  }

  func testWidgetTravelTextAndOldSnapshotsDecode() throws {
    let item = WidgetItem(
      id: "1", title: "Dentist", start: date(16, 14, 38), kind: .event, travelMinutes: 18,
      leaveBy: date(16, 14, 20))
    XCTAssertEqual(item.travelText(now: now, time: hhmm), "Drive 18 min · Leave by 14:20")
    XCTAssertEqual(item.travelText(now: date(16, 14, 25), time: hhmm), "Drive 18 min · Leave now")
    XCTAssertNil(item.travelText(now: date(16, 14, 40), time: hhmm), "started")

    // Leave-by is a timeline date, where "Leave by" turns into "Leave now".
    XCTAssertTrue(
      NextItems.timelineDates(for: [item], now: now, calendar: cal).contains(date(16, 14, 20)))

    let old =
      #"{"generatedAt":"2026-10-16T16:41:00Z","items":[{"id":"1","title":"Dentist","start":"2026-10-16T21:38:00Z","isAllDay":false,"kind":"event"}]}"#
    let snap = try XCTUnwrap(WidgetSnapshot.decode(Data(old.utf8)))
    XCTAssertNil(snap.items.first?.leaveBy)
    let round = try XCTUnwrap(
      WidgetSnapshot.decode(WidgetSnapshot(generatedAt: now, items: [item]).encoded()))
    XCTAssertEqual(round.items, [item])
  }
}

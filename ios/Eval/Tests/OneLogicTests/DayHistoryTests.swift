import XCTest

@testable import TodayCore
@testable import TodayData

/// A past day rebuilt from Activity: what counts as done, and the indexed day queries behind it.
final class DayHistoryTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()
  /// Fri 2026-10-30 00:00 in Los Angeles.
  var day: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 30))! }

  private func at(_ hour: Int, _ minute: Int = 0, plusDays: Int = 0) -> Date {
    let d = cal.date(byAdding: .day, value: plusDays, to: day)!
    return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
  }

  private func event(
    _ kind: String, _ title: String, _ date: Date, ref: String? = nil, subject: String = "task",
    row: Int64 = 0
  ) -> ActivityEvent {
    var e = ActivityEvent(
      kind: kind, tier: ActivityKind.tier(of: kind), actor: "you", at: date, calendar: cal)
    e.title = title
    e.subjectRef = ref
    e.subjectKind = subject
    e.rowID = row
    return e
  }

  private func deletedEvent(_ title: String, start: Date, minutes: Int, deletedAt: Date)
    -> ActivityEvent
  {
    var e = event("change.deleted", title, deletedAt, subject: "event")
    e.beforeTs = ActivityClock.ms(start)
    e.afterTs = ActivityClock.ms(start.addingTimeInterval(Double(minutes) * 60))
    return e
  }

  // MARK: Completions

  func testCompletionsShowAtTheirTimeUnlessUndoneOrReopenedThatDay() {
    let books = event("change.completed", "Return books", at(10, 15), ref: "books")
    let mistake = event("change.completed", "Mistake", at(11), ref: "m")
    let reopen = event("change.reopened", "Mistake", at(11, 1), ref: "m")
    let undone = event("change.completed", "Undone", at(12), ref: "u")
    let h = DayHistory.reconstruct(
      dayEvents: [reopen, books, undone, mistake], deletions: [], undone: [undone.uid])
    XCTAssertEqual(h.completions.map(\.title), ["Return books"])
    XCTAssertEqual(h.completions.first?.at, at(10, 15))
  }

  func testAReopenTakesBackOnlyTheLatestCompletionBeforeIt() {
    // A repeating reminder done twice in a day, the second one reopened: the first still counts.
    let first = event("change.completed", "Vitamins", at(8), ref: "v", row: 1)
    let second = event("change.completed", "Vitamins", at(20), ref: "v", row: 2)
    let reopen = event("change.reopened", "Vitamins", at(20, 1), ref: "v", row: 3)
    let h = DayHistory.reconstruct(dayEvents: [second, reopen, first], deletions: [], undone: [])
    XCTAssertEqual(h.completions.map(\.at), [at(8)])
  }

  func testLiveRowsWinAndReopenedOneOffsDrop() {
    let live = event("change.completed", "Water plants", at(8, 30), ref: "{\"b\":1,\"a\":2}")
    let reopened = event("change.completed", "Call mum", at(9), ref: "call")
    let rolled = event("change.completed", "Vitamins", at(7), ref: "vitamins")
    let noRef = event("change.completed", "Legacy", at(6))
    let normalise: (String) -> String = { $0.replacingOccurrences(of: " ", with: "") }
    let h = DayHistory.reconstruct(
      dayEvents: [live, reopened, rolled, noRef], deletions: [], undone: [],
      shownLive: ["{\"b\":1,\"a\":2}"], reopened: ["call"], key: normalise)
    // A repeating reminder rolled forward is open again but never in `reopened`: its completion stays.
    XCTAssertEqual(h.completions.map(\.title), ["Legacy", "Vitamins"])
  }

  func testOnlyTaskCompletionsCount() {
    let list = event("change.completed", "Some list", at(9), subject: "list")
    XCTAssertTrue(
      DayHistory.reconstruct(dayEvents: [list], deletions: [], undone: []).completions.isEmpty)
  }

  // MARK: Deleted events

  func testAnEventDeletedAfterItStartedStaysAndOneDeletedBeforeDoesNot() {
    let lunch = deletedEvent("Team lunch", start: at(12), minutes: 60, deletedAt: at(15))
    let during = deletedEvent("Long call", start: at(9), minutes: 120, deletedAt: at(10))
    let cancelled = deletedEvent("Cancelled", start: at(16), minutes: 30, deletedAt: at(9))
    let restored = deletedEvent("Restored", start: at(8), minutes: 30, deletedAt: at(18))
    let reminder = event("change.deleted", "A reminder", at(18))
    let h = DayHistory.reconstruct(
      dayEvents: [], deletions: [lunch, cancelled, during, restored, reminder],
      undone: [restored.uid])
    XCTAssertEqual(h.deletedEvents.map(\.title), ["Long call", "Team lunch"])
    XCTAssertEqual(h.deletedEvents.last?.start, at(12))
    XCTAssertEqual(h.deletedEvents.last?.end, at(13))
  }

  // MARK: Alarm stops

  func testAStopMarksTheLatestRingBeforeItAndUnmatchedStopsStandAlone() {
    let stops = [
      DayHistory.AlarmStop(id: "1", title: "Wake", at: at(7, 4), alarmID: "A"),
      DayHistory.AlarmStop(id: "2", title: "Old", at: at(6, 15), alarmID: "gone"),
      // A stop long after the ring (beyond snoozes) belongs to no ring.
      DayHistory.AlarmStop(id: "3", title: "Wake", at: at(13), alarmID: "A"),
    ]
    let rings: [(alarmID: String?, date: Date)] = [("A", at(7)), ("B", at(7)), ("A", at(18))]
    let match = DayHistory.matchStops(rings: rings, stops: stops)
    XCTAssertEqual(match.stopped, [0: at(7, 4)])
    XCTAssertEqual(match.unmatched.map(\.id), ["2", "3"])
  }

  func testAlarmStopsComeFromTheDayEvents() {
    let stop = event("sys.alarm.stopped", "Wake", at(7, 4), ref: "A", subject: "alarm")
    let h = DayHistory.reconstruct(dayEvents: [stop], deletions: [], undone: [])
    XCTAssertEqual(h.alarmStops, [.init(id: stop.uid, title: "Wake", at: at(7, 4), alarmID: "A")])
  }

  // MARK: Store

  func testLoadReadsOnlyThatDayAndDeletedEventsByTheirStart() throws {
    let store = try ActivityStore(location: .memory)
    let before = event("change.completed", "Yesterday's", at(23, plusDays: -1), ref: "y")
    let done = event("change.completed", "Return books", at(10, 15), ref: "books")
    let after = event("change.completed", "Tomorrow's", at(0, 30, plusDays: 1), ref: "t")
    let stop = event("sys.alarm.stopped", "Wake", at(7, 4), ref: "A", subject: "alarm")
    // Deleted a week later: found by its start, not by the day it was deleted.
    let lunch = deletedEvent(
      "Team lunch", start: at(12), minutes: 60, deletedAt: at(9, plusDays: 7))
    let other = deletedEvent(
      "Other day", start: at(12, plusDays: 1), minutes: 60, deletedAt: at(14, plusDays: 1))
    let undone = event("change.completed", "Undone", at(11), ref: "u")
    var undo = event("change.undone", "Undone", at(11, 5), ref: "u")
    undo.undoOf = undone.uid
    try store.insert([before, done, after, stop, lunch, other, undone, undo])
    let h = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(h.completions.map(\.title), ["Return books"])
    XCTAssertEqual(h.alarmStops.map(\.title), ["Wake"])
    XCTAssertEqual(h.deletedEvents.map(\.title), ["Team lunch"])
  }

  func testLoadPagesThroughABusyDay() throws {
    let store = try ActivityStore(location: .memory)
    try store.insert(
      (0..<450).map { i in
        event(
          "change.completed", "Item \(i)", at(8).addingTimeInterval(Double(i) * 60), ref: "r\(i)")
      })
    let h = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(h.completions.count, 450)
  }

  func testHistoryQueriesUseTheirIndexes() throws {
    let plans = try ActivityStore(location: .memory).historyPlans()
    XCTAssertTrue(plans[0].contains("event_kind_day"), plans[0])
    XCTAssertTrue(plans[1].contains("event_kind_before"), plans[1])
  }
}

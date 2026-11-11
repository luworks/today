import XCTest

@testable import TodayCore
@testable import TodayData

/// A past day rebuilt from Activity: what counts as done, and the indexed day queries behind it.
final class DayHistoryTests: XCTestCase {
  func testRescheduleIsAChangeAtExecutionTimeWithPlanContext() {
    var original = event("change.observed", "Family", at(9), ref: "family", subject: "event")
    original.beforeTs = ActivityClock.ms(at(18))
    var moved = event("change.moved", "Family", at(10), ref: "family", subject: "event")
    moved.beforeTs = original.beforeTs
    moved.afterTs = ActivityClock.ms(at(19))
    var revised = event("change.observed", "Family", at(10, 1), ref: "family", subject: "event")
    revised.beforeTs = moved.afterTs
    let history = DayHistory.reconstruct(
      dayEvents: [moved], deletions: [], undone: [],
      observations: [original, revised], related: [moved])
    XCTAssertEqual(history.facts.count, 1)
    XCTAssertEqual(history.facts.first?.event.uid, moved.uid)
    XCTAssertEqual(history.facts.first?.at, at(10))
    XCTAssertEqual(history.facts.first?.isPrimary, false)
    XCTAssertEqual(Set(history.facts.first?.related.map(\.uid) ?? []), [original.uid, revised.uid])
  }

  func testObservationWithoutAnActionStaysOutOfHistoryAfterRenameAndDeletion() {
    var first = event("change.observed", "Family", at(9), ref: "family", subject: "event")
    first.beforeTs = ActivityClock.ms(at(18))
    first.afterTs = ActivityClock.ms(at(18, 30))
    var renamed = first
    renamed.uid = UUID().uuidString
    renamed.ts += 1000
    renamed.title = "Renamed"
    var deleted = event(
      "change.deleted", "Renamed", at(10, plusDays: 1), ref: "family", subject: "event")
    deleted.beforeTs = first.beforeTs
    let history = DayHistory.reconstruct(
      dayEvents: [], deletions: [], undone: [],
      observations: [renamed, first], related: [deleted])
    XCTAssertTrue(history.facts.isEmpty)
    XCTAssertTrue(history.isEmpty)
    XCTAssertTrue(history.completions.isEmpty)
  }

  func testPlanContextKeepsEveryExactOccurrenceActionAndReopenOutcome() {
    var plan = event("change.observed", "Walk", at(7), ref: "series")
    plan.beforeTs = ActivityClock.ms(at(8))
    var done = event("change.completed", "Walk", at(9), ref: "series")
    done.beforeTs = plan.beforeTs
    var reopened = event("change.reopened", "Walk", at(10), ref: "series")
    reopened.beforeTs = plan.beforeTs
    var other = event("change.completed", "Walk", at(11), ref: "series")
    other.beforeTs = ActivityClock.ms(at(8, plusDays: 1))
    let history = DayHistory.reconstruct(
      dayEvents: [done, reopened, other], deletions: [], undone: [],
      observations: [plan])
    XCTAssertEqual(history.facts.count, 3)
    XCTAssertEqual(history.facts.map(\.event.uid), [done.uid, reopened.uid, other.uid])
    let merged = history.facts.first { $0.event.uid == done.uid }!
    XCTAssertTrue(merged.undone)
    XCTAssertFalse(merged.related.contains { $0.uid == other.uid })
  }

  func testObservationAloneIsNotAnActionEvenWhenObservedLater() throws {
    let store = try ActivityStore(location: .memory)
    var plan = event(
      "change.observed", "Family", at(9, plusDays: 1), ref: "family", subject: "event")
    plan.beforeTs = ActivityClock.ms(at(18))
    try store.insert([plan])
    let history = try DayHistory.load(
      from: store, day: day, calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertTrue(history.facts.isEmpty)
    XCTAssertTrue(history.isEmpty)
    XCTAssertEqual(try store.page(ActivityQuery()).map(\.uid), [plan.uid])
    try store.clear()
    XCTAssertTrue(
      try DayHistory.load(
        from: store, day: day, calendar: cal,
        shownLive: [], reopened: [], key: { $0 }
      ).isEmpty)
  }

  func testPlannedOnlyYesterdayWithFuturePostponementHasNoGhostActions() throws {
    let store = try ActivityStore(location: .memory)
    for subject in ["task", "alarm", "event"] {
      var plan = event("change.observed", "Same title", at(7), ref: subject, subject: subject)
      plan.beforeTs = ActivityClock.ms(at(8))
      plan.props = ActivityProps.json(["all_day": true])
      var move = event(
        "change.moved", "Same title", at(9, plusDays: 1), ref: subject, subject: subject)
      move.beforeTs = plan.beforeTs
      move.afterTs = ActivityClock.ms(at(8, plusDays: 2))
      try store.insert([plan, move])
    }
    let past = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertTrue(past.facts.isEmpty)
    XCTAssertTrue(past.isEmpty)
    let movedDay = try DayHistory.load(
      from: store, day: at(0, plusDays: 1), calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(movedDay.facts.count, 3)
    XCTAssertTrue(movedDay.facts.allSatisfy { !$0.isPrimary && $0.at == at(9, plusDays: 1) })
    XCTAssertEqual(try store.page(ActivityQuery()).count, 6, "Projection must preserve raw records")
  }

  func testCompletionSurvivesLaterMoveDeletionReopenAndUndoWithoutObservation() throws {
    let store = try ActivityStore(location: .memory)
    var done = event("change.completed", "Original", at(10), ref: "series")
    done.beforeTs = ActivityClock.ms(at(8))
    done.actor = "agent:Requested assistant"
    done.channel = "chat"
    var next = event("change.completed", "Original", at(11), ref: "series")
    next.beforeTs = ActivityClock.ms(at(8, plusDays: 1))
    var move = event("change.moved", "Renamed", at(9, plusDays: 1), ref: "series")
    move.beforeTs = done.beforeTs
    move.afterTs = ActivityClock.ms(at(8, plusDays: 2))
    var reopen = event("change.reopened", "Renamed", at(10, plusDays: 1), ref: "series")
    reopen.beforeTs = move.afterTs
    var deletion = event("change.deleted", "Renamed", at(11, plusDays: 1), ref: "series")
    deletion.beforeTs = move.afterTs
    var undo = event("change.undone", "Renamed", at(12, plusDays: 1), ref: "series")
    undo.undoOf = done.uid
    try store.insert([done, next, move, reopen, deletion, undo])
    let past = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: ["series"], reopened: ["series"], key: { $0 }
    )
    XCTAssertEqual(past.facts.map(\.event.uid), [done.uid, next.uid])
    XCTAssertEqual(past.facts.map(\.at), [at(10), at(11)])
    XCTAssertEqual(past.facts.map(\.title), ["Original", "Original"])
    XCTAssertTrue(past.facts.allSatisfy(\.isPrimary))
    XCTAssertTrue(past.facts[0].undone)
    XCTAssertEqual(past.facts[0].event.actor, done.actor)
    XCTAssertEqual(past.facts[0].event.channel, "chat")
    XCTAssertFalse(past.facts[1].undone)
    XCTAssertEqual(
      Set(past.facts[0].related.map(\.uid)), [move.uid, reopen.uid, deletion.uid, undo.uid])
    XCTAssertTrue(past.facts[1].related.isEmpty, "Do not join repeats by series or title")
    let later = try DayHistory.load(
      from: store, day: at(0, plusDays: 1), calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(
      Set(later.facts.map(\.event.uid)), [move.uid, reopen.uid, deletion.uid, undo.uid])
    XCTAssertTrue(later.facts.allSatisfy { fact in !fact.related.contains { $0.uid == fact.id } })
    XCTAssertTrue(later.facts.allSatisfy { cal.isDate($0.at, inSameDayAs: at(0, plusDays: 1)) })
  }

  func testDeletionAfterCalendarStartDoesNotProveAttendance() throws {
    let store = try ActivityStore(location: .memory)
    var deletion = deletedEvent(
      "Meeting", start: at(8), minutes: 60, deletedAt: at(10, plusDays: 1))
    deletion.subjectRef = "meeting"
    try store.insert([deletion])
    let past = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertTrue(past.facts.isEmpty)
    XCTAssertTrue(past.isEmpty)
    let later = try DayHistory.load(
      from: store, day: deletion.date, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(later.facts.map(\.event.uid), [deletion.uid])
    XCTAssertEqual(later.facts.first?.at, deletion.date)
    XCTAssertEqual(later.facts.first?.isPrimary, false)
  }

  func testStopWithoutOccurrenceAnchorSurvivesDeletedAlarmButBareScheduleDoesNot() throws {
    let store = try ActivityStore(location: .memory)
    let stop = event("sys.alarm.stopped", "Wake", at(7, 4), ref: "alarm", subject: "alarm")
    var plan = event("change.observed", "Wake", at(6), ref: "alarm", subject: "alarm")
    plan.beforeTs = ActivityClock.ms(at(7))
    let deletion = event(
      "change.deleted", "Wake", at(9, plusDays: 1), ref: "alarm", subject: "alarm")
    try store.insert([stop, plan, deletion])
    let past = try DayHistory.load(
      from: store, day: day, calendar: cal, shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(past.facts.map(\.event.uid), [stop.uid])
    XCTAssertEqual(past.facts.first?.at, at(7, 4))
    XCTAssertEqual(past.facts.first?.action, "Alarm stopped")
    XCTAssertEqual(past.facts.first?.related.map(\.uid), [deletion.uid])
    XCTAssertTrue(past.completions.isEmpty)
  }

  func testEmptyDayHasNoRecordedActions() {
    XCTAssertTrue(DayHistory.reconstruct(dayEvents: [], deletions: [], undone: []).isEmpty)
  }

  @MainActor
  func testPlanObservationsRespectPauseBufferedClearAndRetention() throws {
    let store = try ActivityStore(location: .memory)
    var settings = ActivitySettings()
    settings.paused = true
    let recorder = ActivityRecorder(store: store, settings: { settings }, schedule: { _, _ in })
    var plan = event("change.observed", "Family", at(9), ref: "family", subject: "event")
    plan.beforeTs = ActivityClock.ms(at(18))
    XCTAssertFalse(recorder.record(plan))
    settings.paused = false
    XCTAssertTrue(recorder.record(plan))
    recorder.discardBuffered()
    recorder.flush()
    XCTAssertTrue(try store.page(ActivityQuery()).isEmpty)
    XCTAssertTrue(recorder.record(plan))
    recorder.flush()
    XCTAssertEqual(try store.page(ActivityQuery()).count, 1)
    let later = cal.date(byAdding: .day, value: 91, to: at(9))!
    _ = try store.prune(retention: .days90, now: later, calendar: cal)
    XCTAssertTrue(try store.page(ActivityQuery()).isEmpty)
  }

  func testObservationMetadataPreservesExistingPolicyAndActionProps() {
    let original = ActivityProps.json([
      "authorized": true, "scope": "occurrence", "retention_days": 90,
    ])
    let props = ActivityProps.dictionary(
      ActivityProps.merging(["observed_ms": 123], into: original))
    XCTAssertEqual(props["authorized"] as? Bool, true)
    XCTAssertEqual(props["scope"] as? String, "occurrence")
    XCTAssertEqual(props["retention_days"] as? Int, 90)
    XCTAssertEqual(props["observed_ms"] as? Int, 123)
  }

  func testLaterAlarmSourceDeletionStaysInOccurrenceDetails() {
    var plan = event("change.observed", "Morning alarm", at(6), ref: "alarm", subject: "alarm")
    plan.beforeTs = ActivityClock.ms(at(7))
    let deletion = event(
      "change.deleted", "Morning alarm", at(9, plusDays: 1), ref: "alarm", subject: "alarm")
    var stop = event("sys.alarm.stopped", "Morning alarm", at(7, 4), ref: "alarm", subject: "alarm")
    stop.beforeTs = plan.beforeTs
    let history = DayHistory.reconstruct(
      dayEvents: [stop], deletions: [], undone: [],
      observations: [plan], related: [deletion])
    XCTAssertEqual(history.facts.count, 1)
    XCTAssertEqual(history.facts[0].at, at(7, 4))
    XCTAssertEqual(history.facts[0].action, "Alarm stopped")
    XCTAssertTrue(history.facts[0].isPrimary)
    XCTAssertEqual(history.facts[0].related.map(\.uid), [plan.uid, deletion.uid])
  }

  func testLegacyReopenDoesNotClaimFinalCompletionOrGuessOccurrence() {
    let completed = event("change.completed", "Walk", at(8), ref: "series")
    let reopen = event("change.reopened", "Walk", at(9), ref: "series")
    let history = DayHistory.reconstruct(dayEvents: [completed, reopen], deletions: [], undone: [])
    XCTAssertTrue(history.facts[0].outcomeUnknown)
    XCTAssertTrue(history.facts[0].action.contains("occurrence unknown"))
    XCTAssertEqual(history.facts.count, 2)
    XCTAssertFalse(
      history.facts[0].undone, "missing anchors cannot establish this occurrence was reversed")
  }

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

  func testFactsPreserveUndoReopenAndOccurrencePlanWithoutLiveSources() {
    var first = event("change.completed", "Original title", at(8), ref: "series")
    first.beforeTs = ActivityClock.ms(at(7))
    var second = event("change.completed", "Next occurrence", at(20), ref: "series")
    second.beforeTs = ActivityClock.ms(at(19))
    let reopen = event("change.reopened", "Next occurrence", at(21), ref: "series")
    let h = DayHistory.reconstruct(
      dayEvents: [second, reopen, first], deletions: [],
      undone: [first.uid], shownLive: ["series"], reopened: ["series"])
    XCTAssertEqual(h.facts.map(\.title), ["Original title", "Next occurrence", "Next occurrence"])
    XCTAssertEqual(h.facts.map(\.id), [first.uid, second.uid, reopen.uid])
    XCTAssertTrue(h.facts[0].undone)
    XCTAssertEqual(h.facts[0].event.beforeTs, ActivityClock.ms(at(7)))
    XCTAssertEqual(h.facts[1].event.beforeTs, ActivityClock.ms(at(19)))
  }

  func testFactsFollowStoreRetentionAndDoNotInventMissingPlan() throws {
    let store = try ActivityStore(location: .memory)
    let legacy = event("change.completed", "Deleted source", at(8), ref: "gone")
    try store.insert([legacy])
    let h = try DayHistory.load(
      from: store, day: day, calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertEqual(h.facts.first?.title, "Deleted source")
    XCTAssertNil(h.facts.first?.event.beforeTs)
    XCTAssertEqual(h.facts.first?.id, legacy.uid)
    _ = try store.prune(retention: .days90, now: at(8, plusDays: 100), calendar: cal)
    let expired = try DayHistory.load(
      from: store, day: day, calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertTrue(expired.facts.isEmpty)
    try store.insert([legacy])
    try store.clear()
    let cleared = try DayHistory.load(
      from: store, day: day, calendar: cal,
      shownLive: [], reopened: [], key: { $0 })
    XCTAssertTrue(cleared.facts.isEmpty)
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

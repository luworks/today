import Foundation
import TodayCore
import XCTest

@testable import TodayData

final class TodayFocusStoreTests: XCTestCase {
  private var directory: URL!
  private var url: URL { directory.appendingPathComponent("focus-v1.json") }
  private let now = Date(timeIntervalSince1970: 1_792_000_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "focus-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func identity(
    account: String = "account-1", calendar: String = "calendar-1", item: String = "item-1",
    occurrence: Date? = nil
  ) -> FocusIdentity {
    FocusIdentity(
      provider: "eventkit", account: account, calendar: calendar, item: item, occurrence: occurrence
    )
  }

  private func disk() throws -> TodayFocusStore { try TodayFocusStore(location: .file(url)) }

  func testSettleIsScopedToSelectedDayAndExpiresAfterThatDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9))!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let later = calendar.date(byAdding: .day, value: 2, to: today)!
    let endTomorrow = calendar.startOfDay(for: later)
    let focus = try disk()
    let source = identity()
    try focus.set(state: .settled, for: source, now: today, on: today, calendar: calendar)
    try focus.set(state: .settled, for: source, now: today, on: tomorrow, calendar: calendar)
    XCTAssertEqual(focus.records.count, 2)
    XCTAssertEqual(focus.state(for: source, now: today, on: today, calendar: calendar), .settled)
    XCTAssertEqual(focus.state(for: source, now: today, on: tomorrow, calendar: calendar), .settled)
    XCTAssertNil(focus.state(for: source, now: today, on: later, calendar: calendar))
    let reopened = try disk()
    XCTAssertNil(reopened.state(for: source, now: tomorrow, on: today, calendar: calendar))
    XCTAssertEqual(
      reopened.state(for: source, now: tomorrow, on: tomorrow, calendar: calendar), .settled)
    XCTAssertNil(reopened.state(for: source, now: endTomorrow, on: tomorrow, calendar: calendar))
    try reopened.set(state: .active, for: source, now: today, on: tomorrow, calendar: calendar)
    XCTAssertNil(reopened.state(for: source, now: today, on: tomorrow, calendar: calendar))
    XCTAssertEqual(reopened.state(for: source, now: today, on: today, calendar: calendar), .settled)
  }

  func testSelectedCivilDaySurvivesTimeZoneChange() throws {
    var eastern = Calendar(identifier: .gregorian)
    eastern.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    var pacific = eastern
    pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = eastern.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    let selected = eastern.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let pacificDay = pacific.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let previous = pacific.date(byAdding: .day, value: -1, to: pacificDay)!
    let end = pacific.date(byAdding: .day, value: 1, to: pacificDay)!
    let focus = try disk()
    try focus.set(state: .settled, for: identity(), now: now, on: selected, calendar: eastern)
    let reopened = try disk()
    XCTAssertNil(reopened.state(for: identity(), now: now, on: previous, calendar: pacific))
    XCTAssertEqual(
      reopened.state(for: identity(), now: now, on: pacificDay, calendar: pacific), .settled)
    XCTAssertNil(reopened.state(for: identity(), now: end, on: pacificDay, calendar: pacific))
    try reopened.set(state: .active, for: identity(), now: now, on: pacificDay, calendar: pacific)
    XCTAssertEqual(reopened.records.count, 1)
    XCTAssertNil(reopened.state(for: identity(), now: now, on: pacificDay, calendar: pacific))
  }

  func testLegacySettleBelongsToTheDayItWasChanged() throws {
    let record = FocusRecord(identity: identity(), state: .settled, changedAt: now)
    let recordJSON = String(data: try JSONEncoder().encode(record), encoding: .utf8)!
    try Data("{\"version\":1,\"records\":[\(recordJSON)]}".utf8).write(to: url)
    let focus = try disk()
    XCTAssertEqual(focus.state(for: identity(), now: now), .settled)
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
    XCTAssertNil(focus.state(for: identity(), now: now, on: tomorrow))
    try focus.set(state: .settled, for: identity(), now: now, on: tomorrow)
    XCTAssertEqual(try disk().records.count, 2)
  }

  func testSettleExpiresOnNextLocalDayWhileOpenAndAfterReopen() throws {
    let calendar = Calendar.current
    let start = calendar.date(
      from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 59))!
    let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: start)!)
    let source = identity(occurrence: start)
    let focus = try disk()
    try focus.set(state: .settled, for: source, now: start, localReference: "same-source")
    let bytes = try Data(contentsOf: url)
    XCTAssertEqual(focus.state(for: source, now: midnight.addingTimeInterval(-1)), .settled)
    XCTAssertNil(focus.state(for: source, now: midnight))
    XCTAssertNil(try disk().state(for: source, now: midnight))
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    XCTAssertEqual(focus.records.first?.changedAt, start)
  }

  func testSettleUsesLocalCalendarDaysAcrossDSTWithoutChangingSnooze() throws {
    struct Fixture: Decodable {
      struct Boundary: Decodable {
        let settled: String
        let midnight: String
      }
      let timeZone: String
      let cases: [Boundary]
    }
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../../tests/fixtures/settle-day-boundary.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: fixture.timeZone))
    let formatter = ISO8601DateFormatter()
    for boundary in fixture.cases {
      let start = try XCTUnwrap(formatter.date(from: boundary.settled))
      let midnight = try XCTUnwrap(formatter.date(from: boundary.midnight))
      let runtime = PlannerRuntime(
        now: { midnight }, nextID: { UUID() }, calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX"))
      XCTAssertEqual(runtime.refreshedTodayDay(start, previousNow: start, now: midnight), midnight)
      let browsed = calendar.date(byAdding: .day, value: -2, to: start)!
      XCTAssertEqual(runtime.refreshedTodayDay(browsed, previousNow: start, now: midnight), browsed)
      let focus = try TodayFocusStore(location: .memory)
      let source = identity(occurrence: start)
      try focus.set(state: .settled, for: source, now: start)
      XCTAssertEqual(
        focus.state(for: source, now: midnight.addingTimeInterval(-1), calendar: calendar), .settled
      )
      XCTAssertNil(focus.state(for: source, now: midnight, calendar: calendar))
      XCTAssertNil(focus.state(for: identity(occurrence: midnight), now: start, calendar: calendar))
      let until = midnight.addingTimeInterval(3600)
      try focus.set(state: .snoozed(until: until), for: source, now: start)
      XCTAssertEqual(
        focus.state(for: source, now: midnight, calendar: calendar), .snoozed(until: until))
      XCTAssertNil(focus.state(for: source, now: until, calendar: calendar))
    }
  }

  func testDiskReopenRestoresOverlayAndExplicitClearRemovesIt() throws {
    let settled = identity()
    let snoozed = identity(item: "item-2")
    let until = now.addingTimeInterval(3600)
    do {
      let focus = try disk()
      try focus.set(state: .settled, for: settled, now: now)
      try focus.set(state: .snoozed(until: until), for: snoozed, now: now)
    }
    do {
      let focus = try disk()
      XCTAssertEqual(focus.state(for: settled, now: now), .settled)
      XCTAssertEqual(focus.state(for: snoozed, now: now), .snoozed(until: until))
      try focus.set(state: nil, for: settled, now: now)
      XCTAssertNil(focus.state(for: settled, now: now))
      XCTAssertEqual(focus.records.count, 1)
      try focus.clear()
    }
    XCTAssertTrue(try disk().records.isEmpty)
  }

  func testExplicitActiveRestoreSurvivesDiskAndActivityRecoveryWithoutMovingSourceIdentity() throws
  {
    let oldOccurrence = now.addingTimeInterval(-86400)
    let source = identity(occurrence: oldOccurrence)
    let focus = try disk()
    try focus.set(state: .settled, for: source, now: now)
    try focus.set(state: .active, for: source, now: now)
    let reopened = try disk()
    XCTAssertNil(reopened.state(for: source, now: now))
    XCTAssertEqual(reopened.records.first?.state, .active)
    XCTAssertEqual(reopened.records.first?.identity.occurrence, oldOccurrence)
    let before = try Data(contentsOf: url)
    let history = directory.appendingPathComponent("activity.sqlite")
    try Data("damaged synthetic Activity".utf8).write(to: history)
    let recovered = try ActivityStore.openOrRecover(at: history)
    try recovered.clear()
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(try disk().records.first?.state, .active)
  }

  func testCorruptAndNewerPayloadsAreRejectedWithoutOverwrite() throws {
    for raw in ["not-json", "{\"version\":3,\"future\":true}", "{\"version\":1,\"records\":[{}]}"] {
      let bytes = Data(raw.utf8)
      try bytes.write(to: url)
      XCTAssertThrowsError(try disk())
      XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
  }

  func testOpaqueLocalReferenceSurvivesDiskReopenAndStateUpdates() throws {
    let focus = try disk()
    try focus.set(state: .settled, for: identity(), now: now, localReference: "opaque-local-id")
    let reopened = try disk()
    XCTAssertEqual(reopened.records.first?.localReference, "opaque-local-id")
    try reopened.set(state: .snoozed(until: now.addingTimeInterval(60)), for: identity(), now: now)
    XCTAssertEqual(try disk().records.first?.localReference, "opaque-local-id")
    XCTAssertNil(reopened.state(for: identity(account: "different-source"), now: now))
  }

  func testResolvedIdentityDetachesOlderAnchorWithoutDiscardingSourceDecision() throws {
    let focus = try disk()
    let oldIdentity = identity(account: "old-source")
    let resolvedIdentity = identity(account: "new-source")
    let until = now.addingTimeInterval(60)
    try focus.set(state: .settled, for: oldIdentity, now: now, localReference: "same-local-id")
    try focus.set(
      state: .snoozed(until: until), for: resolvedIdentity, now: now,
      localReference: "same-local-id")
    try focus.detachReference("same-local-id", except: resolvedIdentity)
    let reopened = try disk()
    XCTAssertEqual(
      reopened.records.first(where: { $0.identity == oldIdentity }),
      FocusRecord(identity: oldIdentity, state: .settled, changedAt: now))
    XCTAssertEqual(
      reopened.records.first(where: { $0.identity == resolvedIdentity }),
      FocusRecord(
        identity: resolvedIdentity, state: .snoozed(until: until), changedAt: now,
        localReference: "same-local-id"))
    let bytes = try Data(contentsOf: url)
    try reopened.detachReference("same-local-id", except: resolvedIdentity)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testSnoozeExpiresAtAbsoluteTimeAcrossDSTAndMidnight() throws {
    let formatter = ISO8601DateFormatter()
    // The fall-back hour repeats locally, but the stored instant stays unambiguous.
    let start = try XCTUnwrap(formatter.date(from: "2026-11-01T08:55:00Z"))
    let until = try XCTUnwrap(formatter.date(from: "2026-11-01T10:05:00Z"))
    let focus = try disk()
    try focus.set(state: .snoozed(until: until), for: identity(), now: start)
    XCTAssertEqual(
      focus.state(for: identity(), now: until.addingTimeInterval(-1)), .snoozed(until: until))
    XCTAssertNil(focus.state(for: identity(), now: until))
    XCTAssertNil(focus.state(for: identity(), now: until.addingTimeInterval(86400)))
    XCTAssertNil(try disk().state(for: identity(), now: until))
    try focus.set(state: .settled, for: identity(), now: start)
    XCTAssertNil(focus.state(for: identity(), now: until.addingTimeInterval(86400)))
  }

  func testStableIdentitySurvivesRefreshButDoesNotLeakAcrossSourcesOrOccurrences() throws {
    let first = identity(occurrence: now)
    let focus = try disk()
    try focus.set(state: .settled, for: first, now: now)
    // A refreshed source object supplies the same IDs, independently of title/time edits.
    XCTAssertEqual(focus.state(for: identity(occurrence: now), now: now), .settled)
    for other in [
      identity(account: "account-2", occurrence: now),
      identity(calendar: "calendar-2", occurrence: now),
      identity(item: "item-2", occurrence: now),
      identity(occurrence: now.addingTimeInterval(86400)),
      identity(),
    ] {
      XCTAssertNil(focus.state(for: other, now: now))
    }
  }

  func testInvalidIdentityAndTimeLeaveMemoryAndDiskUnchanged() throws {
    let focus = try disk()
    try focus.set(state: .settled, for: identity(), now: now)
    let prior = focus.records
    let raw = try Data(contentsOf: url)
    for until in [
      now, now.addingTimeInterval(-1), Date(timeIntervalSinceReferenceDate: .infinity),
      Date(timeIntervalSinceReferenceDate: .nan),
    ] {
      XCTAssertThrowsError(try focus.set(state: .snoozed(until: until), for: identity(), now: now))
    }
    XCTAssertThrowsError(try focus.set(state: .settled, for: identity(account: ""), now: now))
    XCTAssertThrowsError(try focus.set(state: .settled, for: identity(calendar: " "), now: now))
    XCTAssertThrowsError(try focus.set(state: .settled, for: identity(item: ""), now: now))
    XCTAssertThrowsError(
      try focus.set(
        state: .settled, for: identity(), now: Date(timeIntervalSinceReferenceDate: .nan)))
    XCTAssertEqual(focus.records, prior)
    XCTAssertEqual(try Data(contentsOf: url), raw)
  }

  func testStaleWriterCannotOverwriteChangedOrCorruptPayload() throws {
    let stale = try disk()
    let current = try disk()
    try current.set(state: .settled, for: identity(), now: now, localReference: "local-id")
    XCTAssertThrowsError(try stale.set(state: .settled, for: identity(item: "other"), now: now)) {
      XCTAssertEqual($0 as? TodayFocusStoreError, .concurrentChange)
    }
    XCTAssertTrue(stale.records.isEmpty)
    XCTAssertEqual(try disk().records, current.records)
    try Data("corrupt".utf8).write(to: url)
    XCTAssertThrowsError(try current.clear())
    XCTAssertThrowsError(
      try current.detachReference("local-id", except: identity(account: "new-source")))
    XCTAssertEqual(current.records.count, 1)
    XCTAssertEqual(current.records.first?.localReference, "local-id")
    XCTAssertEqual(try Data(contentsOf: url), Data("corrupt".utf8))
  }

  func testFileWriteFailurePreservesPriorState() throws {
    let focus = try disk()
    try focus.set(state: .settled, for: identity(), now: now)
    let prior = focus.records
    let raw = try Data(contentsOf: url)
    let held = directory.appendingPathExtension("held")
    try FileManager.default.moveItem(at: directory, to: held)
    try Data("parent-is-a-file".utf8).write(to: directory)
    do {
      defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.moveItem(at: held, to: directory)
      }
      XCTAssertThrowsError(
        try focus.set(state: .snoozed(until: now.addingTimeInterval(60)), for: identity(), now: now)
      )
      XCTAssertEqual(focus.records, prior)
      XCTAssertEqual(try Data(contentsOf: held.appendingPathComponent("focus-v1.json")), raw)
    }
    XCTAssertEqual(try disk().records, prior)
  }
}

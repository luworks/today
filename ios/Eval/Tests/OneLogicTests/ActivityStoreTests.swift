import SQLite3
import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class ActivityStoreTests: XCTestCase {
  var dir: URL!
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  let now = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14, UTC

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "activity-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func memory() throws -> ActivityStore { try ActivityStore(location: .memory) }

  private func change(
    _ title: String, actor: String = "you", kind: String = "change.completed",
    ago: TimeInterval = 0,
    ref: String? = nil, uid: String = UUID().uuidString
  ) -> ActivityEvent {
    var e = ActivityEvent(
      kind: kind, tier: .changes, actor: actor, channel: "app", at: now.addingTimeInterval(-ago),
      calendar: cal)
    e.uid = uid
    e.title = title
    e.subjectKind = "task"
    e.subjectRef = ref
    return e
  }

  // MARK: Schema

  func testNewEventKeepsIdentityStampAndPayloadDefaults() {
    let e = ActivityEvent(kind: "ai.turn", actor: "you", at: now, calendar: cal)
    let stamp = ActivityClock.stamp(now, calendar: cal)
    XCTAssertNotNil(UUID(uuidString: e.uid))
    XCTAssertNotEqual(
      e.uid, ActivityEvent(kind: e.kind, actor: e.actor, at: now, calendar: cal).uid)
    XCTAssertEqual(e.ts, stamp.ts)
    XCTAssertEqual(e.tz, stamp.tz)
    XCTAssertEqual(e.day, stamp.day)
    XCTAssertEqual(e.tier, ActivityTier.ai.rawValue)
    XCTAssertEqual(
      ActivityEvent(kind: "ai.turn", tier: .usage, actor: "you", at: now, calendar: cal).tier, 3)
    XCTAssertEqual(e.device, "")
    XCTAssertEqual(e.props, "{}")
    XCTAssertEqual(e.v, 1)
    XCTAssertEqual(e.sync, 0)
    XCTAssertNil(e.channel)
    XCTAssertNil(e.session)
    XCTAssertNil(e.thread)
    XCTAssertNil(e.subjectKind)
    XCTAssertNil(e.subjectRef)
    XCTAssertNil(e.approval)
    XCTAssertNil(e.undoOf)
    XCTAssertNil(e.title)
    XCTAssertNil(e.beforeText)
    XCTAssertNil(e.afterText)
    XCTAssertNil(e.beforeTs)
    XCTAssertNil(e.afterTs)
    XCTAssertNil(e.rowID)
    XCTAssertNil(e.snapshot)
    XCTAssertFalse(e.hasSnapshot)
    XCTAssertEqual(e.content, [])
  }

  func testHydrationPreservesEveryPersistedFieldAndLoadsPayloadOnlyForExport() throws {
    let s = try memory()
    var e = change(
      "买牛奶\nSecond line", actor: "agent:Calendar", kind: "future.kind", ref: "ref-1",
      uid: "persisted-id")
    e.device = "device-1"
    e.ts = -123_456_789
    e.tz = 345
    e.day = 19_990_102  // Deliberately independent of the reader's current calendar and timestamp.
    e.tier = ActivityTier.usage.rawValue
    e.channel = "sync"
    e.session = "session-1"
    e.thread = "thread-1"
    e.approval = "observed"
    e.undoOf = "previous-id"
    e.beforeText = ""
    e.afterText = "After 🥛"
    e.beforeTs = -9
    e.afterTs = 0
    e.props = "{\"ms\":12}"
    e.v = 7
    e.sync = 2
    e.snapshot = Data([0, 1, 255])
    e.content = [ActivityContent(field: "title", before: "before", after: "after")]
    try s.insert([e])

    var expected = e
    expected.rowID = 1
    expected.hasSnapshot = true
    expected.snapshot = nil
    expected.content = []
    XCTAssertEqual(try s.page(ActivityQuery()), [expected])
    XCTAssertEqual(try s.event(uid: e.uid), expected)
    XCTAssertEqual(try s.snapshot(uid: e.uid), e.snapshot)
    XCTAssertEqual(try s.content(uid: e.uid), e.content)
    var exported: [ActivityEvent] = []
    try s.export { exported += $0 }
    expected.snapshot = e.snapshot
    expected.content = e.content
    XCTAssertEqual(exported, [expected])
  }

  func testHydrationKeepsNullAndMalformedRowFallbacks() throws {
    let url = dir.appendingPathComponent("nullable-fixture.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    let handle = try XCTUnwrap(db)
    defer { sqlite3_close(handle) }
    // A deliberately damaged fixture can contain NULL in otherwise required columns.
    // Production migrations and constraints remain unchanged.
    let schema = ActivityStore.migrations.map { migration in
      ["TEXT", "INTEGER", "BLOB"].reduce(migration) { sql, type in
        sql.replacingOccurrences(of: "\(type) NOT NULL", with: type)
      }
    }.joined(separator: "\n")
    // Preserve partial-index predicates such as `WHERE subject_ref IS NOT NULL`.
    let sql =
      schema + "\n" + """
        PRAGMA user_version = \(ActivityStore.migrations.count);
        INSERT INTO event (id, uid, props, v, sync) VALUES (1, NULL, NULL, NULL, NULL);
        INSERT INTO event (id, uid, ts, tier, kind, actor) VALUES (2, 'invalid-tier', 'bad-number', 999, 'ai.turn', 'you');
        INSERT INTO event (id, uid, tier, kind, actor) VALUES (3, 'null-tier', NULL, 'ai.turn', 'you');
        INSERT INTO event (id, uid, tier, kind, actor) VALUES (4, 'unknown-kind', -1, 'future.kind', 'system');
        """
    let result = sqlite3_exec(handle, sql, nil, nil, nil)
    XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    let s = try ActivityStore(location: .file(url))
    let rows = try s.page(ActivityQuery())
    var expected = ActivityEvent(kind: "", tier: .system, actor: "", at: now, calendar: cal)
    expected.uid = ""
    expected.rowID = 1
    expected.ts = 0
    expected.tz = 0
    expected.day = 0
    XCTAssertEqual(rows.first { $0.rowID == 1 }, expected)
    let malformed = try XCTUnwrap(s.event(uid: "invalid-tier"))
    XCTAssertEqual(malformed.tier, ActivityTier.ai.rawValue, "invalid tier still derives from kind")
    XCTAssertEqual(malformed.ts, 0, "SQLite's integer coercion is unchanged")
    XCTAssertEqual(try s.event(uid: "null-tier")?.tier, ActivityTier.system.rawValue)
    XCTAssertEqual(try s.event(uid: "unknown-kind")?.tier, ActivityTier.system.rawValue)
  }

  func testCreatesSchemaAndRemembersDeviceAcrossOpens() throws {
    let url = dir.appendingPathComponent("a.sqlite")
    let first = try ActivityStore(location: .file(url))
    let id = first.deviceID
    XCTAssertFalse(id.isEmpty)
    try first.insert([change("Buy milk")])
    let second = try ActivityStore(location: .file(url))
    XCTAssertEqual(second.deviceID, id, "the device id is created once")
    XCTAssertEqual(try second.count(), 1, "data survives a reopen; migrations do not run twice")
    XCTAssertEqual(first.diagnostics().journalMode, "wal")
  }

  func testNewerSchemaIsRefusedNotOverwritten() throws {
    let url = dir.appendingPathComponent("b.sqlite")
    _ = try ActivityStore(location: .file(url))
    var raw: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
    sqlite3_exec(raw, "PRAGMA user_version = 99", nil, nil, nil)
    sqlite3_close(raw)
    XCTAssertThrowsError(try ActivityStore.openOrRecover(at: url)) {
      XCTAssertEqual($0 as? ActivityStoreError, .newerSchema(99))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path), "a file from a newer app is left alone")
  }

  func testUnreadableFileIsMovedAsideNotDeleted() throws {
    let url = dir.appendingPathComponent("c.sqlite")
    try Data(repeating: 0x41, count: 4096).write(to: url)
    let store = try ActivityStore.openOrRecover(at: url)
    XCTAssertEqual(try store.count(), 0)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertTrue(
      names.contains { $0.hasPrefix("c.sqlite.damaged-") }, "the damaged file is kept: \(names)")
  }

  // MARK: Insert, page, filter

  func testInsertIsIdempotentOnUID() throws {
    let s = try memory()
    let e = change("Buy milk", uid: "u1")
    XCTAssertEqual(try s.insert([e, e, change("Other", uid: "u2")]), 2)
    XCTAssertEqual(try s.insert([e]), 0, "a known uid adds nothing")
    XCTAssertEqual(try s.count(), 2)
  }

  func testCursorPagingCoversEveryRowOnceEvenWithEqualTimes() throws {
    let s = try memory()
    // 400 events, many sharing the same millisecond.
    try s.insert((0..<400).map { change("t\($0)", ago: Double($0 / 7), uid: "u\($0)") })
    var seen: [String] = []
    var cursor: ActivityCursor?
    while true {
      let page = try s.page(ActivityQuery(tiers: [.changes]), after: cursor, limit: 150)
      if page.isEmpty { break }
      seen += page.map(\.uid)
      cursor = ActivityCursor(after: page.last)
    }
    XCTAssertEqual(seen.count, 400)
    XCTAssertEqual(Set(seen).count, 400, "no row twice, none skipped")
    let all = try s.page(ActivityQuery(), limit: 400)
    XCTAssertEqual(all.map(\.ts), all.map(\.ts).sorted(by: >), "newest first")
  }

  func testRowsArrivingBetweenPagesDoNotShiftThem() throws {
    let s = try memory()
    try s.insert((0..<10).map { change("t\($0)", ago: Double($0 + 10), uid: "u\($0)") })
    let first = try s.page(ActivityQuery(), limit: 5)
    try s.insert([change("new", ago: 0, uid: "new")])
    let second = try s.page(ActivityQuery(), after: ActivityCursor(after: first.last), limit: 5)
    XCTAssertEqual(second.map(\.uid), (5..<10).map { "u\($0)" })
  }

  func testActorTierSinceAndKindFilters() throws {
    let s = try memory()
    try s.insert([
      change("a", actor: "you"), change("b", actor: "ai"), change("c", actor: "siri"),
      change("d", actor: "agent:Apple Reminders"),
      change("old", actor: "you", ago: 40 * 86_400),
    ])
    var ai = ActivityEvent(kind: "ai.turn", actor: "you", at: now, calendar: cal)
    ai.title = nil
    try s.insert([ai])
    func titles(_ q: ActivityQuery) throws -> Set<String> { Set(try s.page(q).compactMap(\.title)) }
    XCTAssertEqual(try titles(ActivityQuery(tiers: [.changes], actors: .you)), ["a", "old"])
    XCTAssertEqual(try titles(ActivityQuery(tiers: [.changes], actors: .ai)), ["b"])
    XCTAssertEqual(try titles(ActivityQuery(tiers: [.changes], actors: .others)), ["c", "d"])
    XCTAssertEqual(try s.count(ActivityQuery(tiers: [.changes])), 5)
    XCTAssertEqual(try s.count(), 6, "tier 2 events are not mixed into the changes list")
    XCTAssertEqual(
      try titles(
        ActivityQuery(tiers: [.changes], sinceMs: ActivityClock.ms(now.addingTimeInterval(-86_400)))
      ).count, 4)
    XCTAssertEqual(try s.page(ActivityQuery(kinds: ["ai.turn"])).count, 1)
    XCTAssertEqual(try s.countByTier(), [.changes: 5, .ai: 1])
  }

  func testSearchFindsChineseAndTreatsWildcardsAsText() throws {
    let s = try memory()
    try s.insert([change("买牛奶"), change("Buy milk"), change("100% done"), change("a_b")])
    func hits(_ q: String) throws -> [String] {
      try s.page(ActivityQuery(search: q)).compactMap(\.title).sorted()
    }
    XCTAssertEqual(try hits("牛奶"), ["买牛奶"], "two Chinese characters match (FTS5 would not)")
    XCTAssertEqual(try hits("MILK"), ["Buy milk"], "case-insensitive")
    XCTAssertEqual(try hits("%"), ["100% done"])
    XCTAssertEqual(try hits("_"), ["a_b"])
  }

  func testSnapshotsAndContentLiveInTheirOwnTables() throws {
    let s = try memory()
    var e = change("Deleted one", kind: "change.deleted", uid: "d1")
    e.snapshot = Data("{\"title\":\"x\"}".utf8)
    e.content = [ActivityContent(field: "title", before: "milk", after: "oat milk")]
    try s.insert([e, change("plain", uid: "p1")])
    let page = try s.page(ActivityQuery())
    XCTAssertEqual(page.first { $0.uid == "d1" }?.hasSnapshot, true)
    XCTAssertEqual(page.first { $0.uid == "p1" }?.hasSnapshot, false)
    XCTAssertEqual(try s.snapshot(uid: "d1"), e.snapshot)
    XCTAssertNil(try s.snapshot(uid: "p1"))
    XCTAssertEqual(try s.content(uid: "d1"), e.content)
    try s.clear()
    XCTAssertNil(
      try s.snapshot(uid: "d1"), "deleting events removes their snapshot and content rows")
    XCTAssertEqual(try s.content(uid: "d1"), [])
  }

  func testUndoneQuery() throws {
    let s = try memory()
    var undo = change("Undid", actor: "you", kind: "change.undone", uid: "undo1")
    undo.undoOf = "orig"
    try s.insert([
      change("orig", actor: "ai", kind: "change.planned", ref: "r1", uid: "orig"), undo,
    ])
    XCTAssertEqual(try s.undone(among: ["orig", "undo1", "x"]), ["orig"])
  }

  func testPageQueriesUseAnIndex() throws {
    let s = try memory()
    for q in [
      ActivityQuery(tiers: [.changes]), ActivityQuery(tiers: [.changes], actors: .you),
      ActivityQuery(tiers: [.changes], actors: .others, sinceMs: 1),
    ] {
      let plan = try s.plan(for: q, after: ActivityCursor(ts: 5, id: 5))
      XCTAssertTrue(
        plan.contains("USING INDEX") || plan.contains("USING COVERING INDEX"),
        "uses an index: \(plan)")
      XCTAssertFalse(plan.contains("SCAN e\n") || plan == "SCAN e", "no full scan: \(plan)")
    }
  }

  // MARK: Retention

  func testPruneFollowsEachTiersWindowAndTheRetentionSetting() throws {
    func fill(_ s: ActivityStore) throws {
      var evs: [ActivityEvent] = []
      for days in [1, 60, 120, 300, 500] {
        evs.append(change("c\(days)", ago: Double(days) * 86_400, uid: "c\(days)"))
        var ai = ActivityEvent(
          kind: "ai.turn", actor: "you", at: now.addingTimeInterval(-Double(days) * 86_400),
          calendar: cal)
        ai.uid = "a\(days)"
        evs.append(ai)
      }
      try s.insert(evs)
    }
    let a = try memory()
    try fill(a)
    try a.prune(retention: .year, now: now, calendar: cal)
    XCTAssertEqual(
      Set(try a.page(ActivityQuery(tiers: [.changes])).map(\.uid)), ["c1", "c60", "c120", "c300"],
      "explicit 1 year")
    XCTAssertEqual(
      Set(try a.page(ActivityQuery(tiers: [.ai])).map(\.uid)), ["a1", "a60", "a120"],
      "AI decisions: 180 days")

    let b = try memory()
    try fill(b)
    try b.prune(retention: .days90, now: now, calendar: cal)
    XCTAssertEqual(Set(try b.page(ActivityQuery(tiers: [.changes])).map(\.uid)), ["c1", "c60"])

    let c = try memory()
    try fill(c)
    try c.prune(retention: .forever, now: now, calendar: cal)
    XCTAssertEqual(try c.count(ActivityQuery(tiers: [.changes])), 5, "forever keeps every change")
  }

  func testDefaultRetentionAndExplicitSavedChoices() throws {
    let suite = "activity-retention-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(ActivitySettings().retention, .forever)
    XCTAssertEqual(ActivitySettings(defaults).retention, .forever)
    for choice in [ActivityRetention.days90, .year, .forever] {
      defaults.set(choice.rawValue, forKey: ActivitySettings.retentionKey)
      XCTAssertEqual(ActivitySettings(defaults).retention, choice)
    }
  }

  func testForeverKeepsRawEventsAndContentAcrossAllTiersButExpiresSnapshots() throws {
    let s = try memory()
    var events: [ActivityEvent] = []
    for tier in ActivityTier.allCases {
      var e = ActivityEvent(
        kind: "test.\(tier.rawValue)", tier: tier, actor: "you",
        at: now.addingTimeInterval(-500 * 86_400), calendar: cal)
      e.uid = "old-\(tier.rawValue)"
      e.beforeText = "before"
      e.afterText = "after"
      e.content = [ActivityContent(field: "title", before: "old", after: "new")]
      e.snapshot = Data("undo".utf8)
      events.append(e)
    }
    try s.insert(events)
    for _ in 0..<2 {
      let result = try s.prune(retention: .forever, now: now, calendar: cal)
      XCTAssertEqual(result.changes, 0)
      XCTAssertEqual(result.ai, 0)
      XCTAssertEqual(result.usageAndSystem, 0)
      XCTAssertEqual(try s.count(), events.count)
      XCTAssertTrue(try s.rollups().isEmpty)
    }
    var exported: [ActivityEvent] = []
    try s.export { exported.append(contentsOf: $0) }
    XCTAssertEqual(exported.count, events.count)
    for event in exported {
      XCTAssertEqual(event.beforeText, "before")
      XCTAssertEqual(event.afterText, "after")
      XCTAssertEqual(event.content, [ActivityContent(field: "title", before: "old", after: "new")])
      XCTAssertNil(event.snapshot)
    }
  }

  func testFiniteChoicesKeepFixedWindowsForOtherTiers() throws {
    for retention in [ActivityRetention.days90, .year] {
      let s = try memory()
      var events: [ActivityEvent] = []
      for tier in [ActivityTier.ai, .usage, .system] {
        for days in [10, 45, 100, 200] {
          var e = ActivityEvent(
            kind: "test.\(tier.rawValue)", tier: tier, actor: "you",
            at: now.addingTimeInterval(-Double(days) * 86_400), calendar: cal)
          e.uid = "\(tier.rawValue)-\(days)"
          events.append(e)
        }
      }
      try s.insert(events)
      let result = try s.prune(retention: retention, now: now, calendar: cal)
      XCTAssertEqual(result.ai, 1)
      XCTAssertEqual(result.usageAndSystem, 5)
      XCTAssertEqual(
        Set(try s.page(ActivityQuery(tiers: [.ai])).map(\.uid)), ["2-10", "2-45", "2-100"])
      XCTAssertEqual(Set(try s.page(ActivityQuery(tiers: [.usage])).map(\.uid)), ["3-10"])
      XCTAssertEqual(Set(try s.page(ActivityQuery(tiers: [.system])).map(\.uid)), ["4-10", "4-45"])
      XCTAssertEqual(try s.rollups().reduce(0) { $0 + $1.n }, 5)
    }
  }

  func testUsageAndSystemEventsAreRolledUpBeforeTheyExpire() throws {
    let s = try memory()
    var evs: [ActivityEvent] = []
    for i in 0..<3 {
      var u = ActivityEvent(
        kind: "ui.quickadd.commit", actor: "you",
        at: now.addingTimeInterval(-40 * 86_400 + Double(i)), calendar: cal,
        props: ActivityProps.json(["ms": 1000 * (i + 1)]))
      u.uid = "u\(i)"
      evs.append(u)
    }
    var fresh = ActivityEvent(kind: "ui.screen.open", actor: "you", at: now, calendar: cal)
    fresh.uid = "fresh"
    evs.append(fresh)
    try s.insert(evs)
    let r = try s.prune(retention: .year, now: now, calendar: cal)
    XCTAssertEqual(r.usageAndSystem, 3)
    XCTAssertEqual(try s.count(), 1)
    let rolled = try s.rollups()
    XCTAssertEqual(rolled.count, 1)
    XCTAssertEqual(rolled[0].kind, "ui.quickadd.commit")
    XCTAssertEqual(rolled[0].n, 3)
    XCTAssertEqual(rolled[0].sumMs, 6000, "the durations are summed (JSON functions are available)")
    // Pruning again does not count them twice.
    try s.prune(retention: .year, now: now, calendar: cal)
    XCTAssertEqual(try s.rollups()[0].n, 3)
  }

  func testSnapshotsExpireAfterThirtyDaysButTheEventStays() throws {
    let s = try memory()
    var old = change("Deleted long ago", kind: "change.deleted", ago: 45 * 86_400, uid: "old")
    old.snapshot = Data("x".utf8)
    var recent = change("Deleted lately", kind: "change.deleted", ago: 2 * 86_400, uid: "recent")
    recent.snapshot = Data("y".utf8)
    try s.insert([old, recent])
    XCTAssertEqual(try s.prune(retention: .year, now: now, calendar: cal).snapshots, 1)
    XCTAssertNil(try s.snapshot(uid: "old"))
    XCTAssertNotNil(try s.snapshot(uid: "recent"))
    XCTAssertNotNil(try s.event(uid: "old"), "the history line stays; only Undo is gone")
  }

  func testClearKeepsTheDeviceAndMigrationMarkers() throws {
    let url = dir.appendingPathComponent("d.sqlite")
    let s = try ActivityStore(location: .file(url))
    try s.setMeta(LedgerImport.migratedKey, "1")
    try s.insert([change("x")])
    let device = s.deviceID
    try s.clear()
    XCTAssertEqual(try s.count(), 0)
    XCTAssertEqual(
      try s.meta(LedgerImport.migratedKey), "1",
      "Clear must not make the old ledger import run again")
    XCTAssertEqual(try ActivityStore(location: .file(url)).deviceID, device)
  }

  func testClearOneTierLeavesTheOthers() throws {
    let s = try memory()
    var ai = ActivityEvent(kind: "ai.turn", actor: "you", at: now, calendar: cal)
    ai.uid = "ai1"
    try s.insert([change("x"), ai])
    try s.clear(tiers: [.ai])
    XCTAssertEqual(try s.countByTier(), [.changes: 1])
  }

  // MARK: Export formats

  func testJSONLRoundTripsEveryFieldIncludingNewlinesAndChinese() throws {
    var e = change(
      "买牛奶, \"2 个\"\n第二行", actor: "agent:Apple Reminders", kind: "change.deleted", ref: "{\"a\":1}",
      uid: "x-1")
    e.device = "dev"
    e.session = "s1"
    e.thread = "t1"
    e.approval = "observed"
    e.undoOf = "u0"
    e.beforeText = "Planned 09:00"
    e.afterText = ""
    e.beforeTs = 1_000
    e.afterTs = 2_000
    e.props = ActivityProps.json(["ms": 12, "ids": ["a", "b"], "ok": true])
    e.snapshot = Data([0, 1, 2, 255])
    e.content = [ActivityContent(field: "title", before: "牛奶", after: nil)]
    let line = ActivityJSONL.line(e)
    XCTAssertFalse(line.contains("\n"), "one event per line")
    var back = try XCTUnwrap(ActivityJSONL.event(from: line))
    back.rowID = nil
    XCTAssertEqual(back, e)
  }

  func testJSONLReaderIgnoresUnknownKeysAndSkipsBrokenLines() {
    let text = """
      {"kind":"ai.turn","actor":"you","ts":5,"future_field":{"a":1},"props":{"len_in":3}}
      {"kind":"ai.turn","actor":"you","ts":
      not json
      {"kind":"ui.screen.open","actor":"you","ts":6}
      """
    let events = ActivityJSONL.events(from: text)
    XCTAssertEqual(events.map(\.kind), ["ai.turn", "ui.screen.open"])
    XCTAssertEqual(events[0].tier, 2)
    XCTAssertEqual(events[1].tier, 3)
    XCTAssertEqual(ActivityProps.dictionary(events[0].props)["len_in"] as? Int, 3)
  }

  func testCSVQuotesCommasQuotesAndLineBreaks() {
    XCTAssertEqual(ActivityCSV.field("plain"), "plain")
    XCTAssertEqual(ActivityCSV.field("a,b"), "\"a,b\"")
    XCTAssertEqual(ActivityCSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    XCTAssertEqual(ActivityCSV.field("two\nlines"), "\"two\nlines\"")
    XCTAssertEqual(ActivityCSV.field("买牛奶，两盒"), "买牛奶，两盒", "the full-width comma needs no quoting")
    var e = change("Buy milk, \"oat\"", uid: "u1")
    e.props = ActivityProps.json(["x": 1])
    let row = ActivityCSV.row(e)
    XCTAssertTrue(row.hasSuffix("\r\n"))
    XCTAssertTrue(row.contains("\"Buy milk, \"\"oat\"\"\""))
    XCTAssertTrue(row.contains("\"{\"\"x\"\":1}\""), "props is one JSON cell")
    XCTAssertEqual(ActivityCSV.header.split(separator: ",").count, ActivityCSV.columns.count)
    XCTAssertTrue(
      ActivityCSV.localTime(e).hasSuffix("+00:00") || ActivityCSV.localTime(e).hasSuffix("Z"))
  }

  func testExportStreamsEverythingInBatches() throws {
    let s = try memory()
    var evs = (0..<1234).map { change("t\($0)", ago: Double($0), uid: "u\($0)") }
    evs[3].snapshot = Data("snap".utf8)
    evs[4].content = [ActivityContent(field: "title", before: "a", after: "b")]
    try s.insert(evs)
    let jsonl = dir.appendingPathComponent("out.jsonl")
    XCTAssertEqual(try ActivityExport.write(.jsonl, from: s, to: jsonl), 1234)
    let parsed = ActivityJSONL.events(from: try String(contentsOf: jsonl, encoding: .utf8))
    XCTAssertEqual(parsed.count, 1234)
    XCTAssertEqual(Set(parsed.map(\.uid)).count, 1234)
    XCTAssertNotNil(parsed.first { $0.uid == "u3" }?.snapshot, "the JSONL export carries snapshots")
    XCTAssertEqual(parsed.first { $0.uid == "u4" }?.content.count, 1)
    let csv = dir.appendingPathComponent("out.csv")
    XCTAssertEqual(try ActivityExport.write(.csv, from: s, to: csv), 1234)
    let lines = try String(contentsOf: csv, encoding: .utf8).components(separatedBy: "\r\n")
    XCTAssertEqual(lines.count, 1236, "header + rows + trailing empty piece")
  }

  func testRedactedDropsEverythingPersonalAndCoarsensTime() {
    var e = change("Call Mom", ref: "ref", uid: "x")
    e.thread = "t"
    e.beforeText = "a"
    e.afterText = "b"
    e.snapshot = Data([1])
    e.undoOf = "u"
    e.content = [ActivityContent(field: "title", before: "a", after: "b")]
    e.ts = 3_600_000 * 7 + 123_456
    e.props = ActivityProps.json(["ms": 5])
    let r = e.redacted()
    XCTAssertNil(r.title)
    XCTAssertNil(r.beforeText)
    XCTAssertNil(r.thread)
    XCTAssertNil(r.subjectRef)
    XCTAssertNil(r.snapshot)
    XCTAssertTrue(r.content.isEmpty)
    XCTAssertEqual(r.ts, 3_600_000 * 7)
    XCTAssertEqual(r.kind, e.kind)
    XCTAssertEqual(r.props, e.props, "counts and durations stay")
  }

  // MARK: Benchmark

  func testBenchmarkRunsAndReportsNumbers() throws {
    let r = try ActivityBenchmark.run(rows: 5_000, in: dir)
    XCTAssertEqual(r.rows, 5_000)
    XCTAssertGreaterThan(r.insertRowsPerSecond, 1_000)
    XCTAssertLessThan(r.newestPageMs, 250)
    print("ACTIVITY BENCH (5k, quick):\n" + r.summary)
  }

  /// `ACTIVITY_BENCH_ROWS=100000 swift test --filter testBenchmarkLarge` for the numbers in the README.
  func testBenchmarkLarge() throws {
    guard let n = ProcessInfo.processInfo.environment["ACTIVITY_BENCH_ROWS"].flatMap(Int.init)
    else { throw XCTSkip("set ACTIVITY_BENCH_ROWS") }
    let r = try ActivityBenchmark.run(rows: n, in: dir)
    print("ACTIVITY BENCH (\(n)):\n" + r.summary)
    XCTAssertLessThan(r.deepPageMs, 100)
  }
}

import Foundation
import SQLite3
import TodayCore
import TodayShared

// The Activity data store: one app-private SQLite file (system SQLite3, no dependency), WAL, `user_version` migrations.
// Layout and reasons: docs/research/activity-data-store.md §3. Only the app opens this file. Extensions and widgets append JSONL
// to the App Group outbox instead (`Shared/ActivityOutbox.swift`), which the app imports (`ActivityOutboxImport`).
// Compiled into the `OneLogic` SPM target, so `swift test` runs it against a temp file or `:memory:`.

/// What the recorder needs from a store (a seam for tests).
public protocol ActivityStoring: AnyObject {
  /// Inserts events (and their snapshots and content rows) in one transaction. Rows whose `uid` exists are skipped.
  /// Returns the number of new events.
  @discardableResult func insert(_ events: [ActivityEvent]) throws -> Int
}

public struct ActivityQuery: Equatable {
  public init(
    tiers: [ActivityTier] = [], actors: Actors = .all, sinceMs: Int64? = nil, search: String? = nil,
    subjectRef: String? = nil, kinds: [String] = []
  ) {
    self.tiers = tiers
    self.actors = actors
    self.sinceMs = sinceMs
    self.search = search
    self.subjectRef = subjectRef
    self.kinds = kinds
  }
  /// The Activity filter chips: All / You / AI / Agents (everything that is neither you nor Today AI).
  public enum Actors: Equatable { case all, you, ai, others }

  /// Empty = every tier.
  public var tiers: [ActivityTier] = []
  public var actors: Actors = .all
  /// Only events at or after this time (unix ms).
  public var sinceMs: Int64?
  /// Case-insensitive substring of the title, before or after text (LIKE on the bounded window; Chinese works, FTS5 would not).
  public var search: String?
  public var subjectRef: String?
  public var kinds: [String] = []
}

/// Where the next page starts: after the last row of the previous one, in (ts, id) order, so rows arriving meanwhile do not shift pages.
public struct ActivityCursor: Equatable {
  public var ts: Int64
  public var id: Int64

  public init(ts: Int64, id: Int64) {
    self.ts = ts
    self.id = id
  }

  public init?(after event: ActivityEvent?) {
    guard let event, let id = event.rowID else { return nil }
    self.init(ts: event.ts, id: id)
  }
}

public enum ActivityStoreError: Error, Equatable {
  case open(String)
  case sql(String)
  /// The file was written by a newer version of the app.
  case newerSchema(Int)
}

public struct ActivityPruneResult: Equatable {
  public var changes = 0, ai = 0, usageAndSystem = 0, snapshots = 0
}

public struct ActivityDiagnostics: Equatable {
  public var sqliteVersion: String
  public var fts5: Bool
  public var json: Bool
  public var journalMode: String
}

public final class ActivityStore: ActivityStoring, @unchecked Sendable {
  public enum Location: Equatable {
    case memory
    case file(URL)
  }

  public static let schemaVersion = 1

  public let location: Location
  private var db: OpaquePointer?
  /// One connection, one lock: the recorder (main), the Activity screen (main) and an export (background) never overlap statements.
  private let lock = NSRecursiveLock()
  /// Random id of this install, created at first open.
  private(set) var deviceID = ""

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  // MARK: Open

  public init(location: Location) throws {
    self.location = location
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let path: String
    switch location {
    case .memory:
      path = ":memory:"
    case .file(let url):
      let dir = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      Self.protect(dir)
      path = url.path
    }
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      if let handle { sqlite3_close(handle) }
      throw ActivityStoreError.open(message)
    }
    db = handle
    sqlite3_busy_timeout(handle, 2000)
    do {
      try configure()
      try migrate()
      deviceID = try ensureDeviceID()
    } catch {
      sqlite3_close(handle)
      db = nil
      throw error
    }
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  /// Opens the file; a file SQLite cannot read is moved aside (never deleted) and a new one is started.
  public static func openOrRecover(at url: URL) throws -> ActivityStore {
    do {
      return try ActivityStore(location: .file(url))
    } catch let error as ActivityStoreError {
      if case .newerSchema = error { throw error }
      let fm = FileManager.default
      guard fm.fileExists(atPath: url.path) else { throw error }
      let stamp = Int(Date.now.timeIntervalSince1970)
      for suffix in ["", "-wal", "-shm"] {
        let from = URL(fileURLWithPath: url.path + suffix)
        if fm.fileExists(atPath: from.path) {
          try? fm.moveItem(
            at: from, to: URL(fileURLWithPath: url.path + ".damaged-\(stamp)" + suffix))
        }
      }
      return try ActivityStore(location: .file(url))
    }
  }

  /// `Application Support/Activity/activity.sqlite`: in the app container, not the App Group.
  public static func defaultURL() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Activity", isDirectory: true).appendingPathComponent(
      "activity.sqlite")
  }

  /// New files in the directory stay readable after the first unlock, so a write while the phone is locked works.
  public static func protect(_ directory: URL) {
    #if os(iOS)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path)
    #endif
  }

  private func configure() throws {
    _ = try? rows("PRAGMA journal_mode = WAL") { $0.text(0) }
    try exec("PRAGMA synchronous = NORMAL")
    try exec("PRAGMA foreign_keys = ON")
  }

  // MARK: Schema

  /// Ordered; entry i brings `user_version` to i + 1. Never edit an old entry, add a new one.
  public static let migrations: [String] = [
    """
    CREATE TABLE event (
      id           INTEGER PRIMARY KEY,
      uid          TEXT NOT NULL UNIQUE,
      device       TEXT NOT NULL,
      ts           INTEGER NOT NULL,
      tz           INTEGER NOT NULL,
      day          INTEGER NOT NULL,
      tier         INTEGER NOT NULL,
      kind         TEXT NOT NULL,
      actor        TEXT NOT NULL,
      channel      TEXT,
      session      TEXT,
      thread       TEXT,
      subject_kind TEXT,
      subject_ref  TEXT,
      approval     TEXT,
      undo_of      TEXT,
      title        TEXT,
      before_txt   TEXT,
      after_txt    TEXT,
      before_ts    INTEGER,
      after_ts     INTEGER,
      props        TEXT NOT NULL DEFAULT '{}',
      v            INTEGER NOT NULL DEFAULT 1,
      sync         INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX event_ts       ON event(ts DESC, id DESC);
    CREATE INDEX event_tier_ts  ON event(tier, ts DESC, id DESC);
    CREATE INDEX event_actor_ts ON event(actor, ts DESC, id DESC);
    CREATE INDEX event_subject  ON event(subject_ref, ts DESC) WHERE subject_ref IS NOT NULL;
    CREATE INDEX event_kind_day ON event(kind, day);
    CREATE INDEX event_undo     ON event(undo_of) WHERE undo_of IS NOT NULL;
    CREATE TABLE snapshot (
      event_uid TEXT PRIMARY KEY REFERENCES event(uid) ON DELETE CASCADE,
      data      BLOB NOT NULL
    );
    CREATE TABLE content (
      event_uid  TEXT NOT NULL REFERENCES event(uid) ON DELETE CASCADE,
      field      TEXT NOT NULL,
      before_txt TEXT,
      after_txt  TEXT,
      PRIMARY KEY (event_uid, field)
    ) WITHOUT ROWID;
    CREATE TABLE rollup_daily (
      day    INTEGER NOT NULL,
      kind   TEXT NOT NULL,
      actor  TEXT NOT NULL,
      n      INTEGER NOT NULL,
      sum_ms INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (day, kind, actor)
    ) WITHOUT ROWID;
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """,
    // 2: a past day's deleted events, found by when they were (`before_ts`), not when they were deleted.
    """
    CREATE INDEX event_kind_before ON event(kind, before_ts) WHERE before_ts IS NOT NULL;
    """,
  ]

  private func migrate() throws {
    let current = Int(try rows("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0)
    if current > Self.migrations.count { throw ActivityStoreError.newerSchema(current) }
    guard current < Self.migrations.count else { return }
    for version in (current + 1)...Self.migrations.count {
      try transaction {
        try exec(Self.migrations[version - 1])
        try exec("PRAGMA user_version = \(version)")
      }
    }
  }

  private func ensureDeviceID() throws -> String {
    if let id = try meta("device") { return id }
    let id = UUID().uuidString
    try setMeta("device", id)
    return id
  }

  // MARK: Writing

  @discardableResult
  public func insert(_ events: [ActivityEvent]) throws -> Int {
    guard !events.isEmpty else { return 0 }
    return try transaction {
      var inserted = 0
      let insertEvent = try Statement(
        db!,
        """
        INSERT OR IGNORE INTO event (uid, device, ts, tz, day, tier, kind, actor, channel, session, thread, subject_kind,
          subject_ref, approval, undo_of, title, before_txt, after_txt, before_ts, after_ts, props, v, sync)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """)
      let insertSnapshot = try Statement(
        db!, "INSERT OR IGNORE INTO snapshot (event_uid, data) VALUES (?,?)")
      let insertContent = try Statement(
        db!,
        "INSERT OR REPLACE INTO content (event_uid, field, before_txt, after_txt) VALUES (?,?,?,?)")
      for e in events {
        let device = e.device.isEmpty ? deviceID : e.device
        try insertEvent.run([
          e.uid, device, e.ts, e.tz, e.day, e.tier, e.kind, e.actor, e.channel, e.session, e.thread,
          e.subjectKind, e.subjectRef, e.approval, e.undoOf, e.title, e.beforeText, e.afterText,
          e.beforeTs, e.afterTs, e.props, e.v, e.sync,
        ])
        guard sqlite3_changes(db) > 0 else { continue }
        inserted += 1
        if let snapshot = e.snapshot { try insertSnapshot.run([e.uid, snapshot]) }
        for c in e.content { try insertContent.run([e.uid, c.field, c.before, c.after]) }
      }
      return inserted
    }
  }

  /// Forever keeps raw events in every tier. For finite settings, changes follow the chosen window, AI expires after
  /// 180 days, usage after 30 and system after 90 (usage and system are rolled up first). Undo snapshots expire after
  /// 30 days regardless of the setting; event text and content are retained for as long as their event is kept.
  @discardableResult
  public func prune(retention: ActivityRetention, now: Date = .now, calendar: Calendar = .current)
    throws -> ActivityPruneResult
  {
    var result = ActivityPruneResult()
    try transaction {
      if let cutoff = retention.cutoff(now: now, calendar: calendar) {
        result.changes = try execCount(
          "DELETE FROM event WHERE tier = 1 AND ts < ?", [ActivityClock.ms(cutoff)])
        let aiCut = ActivityWindows.cutoffMs(
          days: ActivityWindows.aiDays, now: now, calendar: calendar)
        result.ai = try execCount("DELETE FROM event WHERE tier = 2 AND ts < ?", [aiCut])
        for (tier, days) in [(3, ActivityWindows.usageDays), (4, ActivityWindows.systemDays)] {
          let cut = ActivityWindows.cutoffMs(days: days, now: now, calendar: calendar)
          try rollUp(tier: tier, before: cut)
          result.usageAndSystem += try execCount(
            "DELETE FROM event WHERE tier = ? AND ts < ?", [tier, cut])
        }
      }
      let snapCut = ActivityWindows.cutoffMs(
        days: ActivityWindows.snapshotDays, now: now, calendar: calendar)
      result.snapshots = try execCount(
        "DELETE FROM snapshot WHERE event_uid IN (SELECT uid FROM event WHERE ts < ?)", [snapCut])
    }
    return result
  }

  /// Adds the per-day counts (and summed `ms`) of expiring rows to `rollup_daily`.
  private func rollUp(tier: Int, before cut: Int64) throws {
    func sql(_ sumExpr: String) -> String {
      """
      INSERT INTO rollup_daily (day, kind, actor, n, sum_ms)
      SELECT day, kind, actor, COUNT(*), \(sumExpr) FROM event WHERE tier = ? AND ts < ? GROUP BY day, kind, actor
      ON CONFLICT (day, kind, actor) DO UPDATE SET n = n + excluded.n, sum_ms = sum_ms + excluded.sum_ms
      """
    }
    do {
      try exec(sql("COALESCE(SUM(CAST(json_extract(props, '$.ms') AS INTEGER)), 0)"), [tier, cut])
    } catch {
      // A SQLite without the JSON functions: keep the counts, lose the summed durations.
      try exec(sql("0"), [tier, cut])
    }
  }

  /// Deletes events of these tiers (nil = all of them, plus the daily counts). Settings and the device id stay.
  public func clear(tiers: Set<ActivityTier>? = nil) throws {
    try transaction {
      if let tiers, tiers.count < ActivityTier.allCases.count {
        let list = tiers.map { String($0.rawValue) }.sorted().joined(separator: ",")
        try exec("DELETE FROM event WHERE tier IN (\(list))")
      } else {
        try exec("DELETE FROM event")
        try exec("DELETE FROM rollup_daily")
      }
    }
    if tiers == nil || tiers?.count == ActivityTier.allCases.count {
      _ = try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
      _ = try? exec("VACUUM")
    }
  }

  // MARK: Reading

  /// A page of events, newest first. Pass the cursor of the last row of the previous page to continue.
  public func page(_ query: ActivityQuery, after cursor: ActivityCursor? = nil, limit: Int = 150)
    throws -> [ActivityEvent]
  {
    var (conds, args) = Self.conditions(query)
    if let cursor {
      conds.append("(e.ts < ? OR (e.ts = ? AND e.id < ?))")
      args += [cursor.ts, cursor.ts, cursor.id]
    }
    let sql =
      "SELECT \(Self.columns) FROM event e" + Self.whereClause(conds)
      + " ORDER BY e.ts DESC, e.id DESC LIMIT ?"
    return try rows(sql, args + [max(1, limit)]) { Self.event($0) }
  }

  /// One local day's events of these kinds (`day` is the yyyymmdd stamped when written), newest first, a page at a time.
  /// Uses `event_kind_day`.
  public func dayPage(
    kinds: [String], day: Int, after cursor: ActivityCursor? = nil, limit: Int = 200
  ) throws -> [ActivityEvent] {
    let (sql, args) = Self.daySQL(kinds: kinds, day: day, cursor: cursor)
    return try rows(
      "SELECT \(Self.columns) FROM event e" + sql + " LIMIT ?", args + [max(1, limit)]
    ) { Self.event($0) }
  }

  /// Events of one kind whose `before_ts` lies in `[startMs, endMs)`, newest first, a page at a time: a deleted calendar
  /// event carries its start there, so a past day finds the events it had whenever they were deleted. Uses `event_kind_before`.
  public func beforePage(
    kind: String, startMs: Int64, endMs: Int64, after cursor: ActivityCursor? = nil,
    limit: Int = 200
  ) throws -> [ActivityEvent] {
    let (sql, args) = Self.beforeSQL(kind: kind, startMs: startMs, endMs: endMs, cursor: cursor)
    return try rows(
      "SELECT \(Self.columns) FROM event e" + sql + " LIMIT ?", args + [max(1, limit)]
    ) { Self.event($0) }
  }

  /// Query plans of `dayPage` and `beforePage` (tests check both use their index).
  public func historyPlans() throws -> [String] {
    let cursor = ActivityCursor(ts: 5, id: 5)
    return try [
      Self.daySQL(kinds: ["change.completed", "change.reopened"], day: 20_261_030, cursor: cursor),
      Self.beforeSQL(kind: "change.deleted", startMs: 0, endMs: 1, cursor: cursor),
    ].map { sql, args in
      try rows("EXPLAIN QUERY PLAN SELECT e.id FROM event e" + sql, args) { $0.text(3) ?? "" }
        .joined(separator: "\n")
    }
  }

  private static func daySQL(kinds: [String], day: Int, cursor: ActivityCursor?) -> (
    String, [Any?]
  ) {
    var conds = [
      "e.kind IN (" + Array(repeating: "?", count: max(1, kinds.count)).joined(separator: ",")
        + ")", "e.day = ?",
    ]
    var args: [Any?] = (kinds.isEmpty ? [""] : kinds) + [day]
    if let cursor {
      conds.append("(e.ts < ? OR (e.ts = ? AND e.id < ?))")
      args += [cursor.ts, cursor.ts, cursor.id]
    }
    return (whereClause(conds) + " ORDER BY e.ts DESC, e.id DESC", args)
  }

  private static func beforeSQL(kind: String, startMs: Int64, endMs: Int64, cursor: ActivityCursor?)
    -> (String, [Any?])
  {
    var conds = ["e.kind = ?", "e.before_ts >= ?", "e.before_ts < ?"]
    var args: [Any?] = [kind, startMs, endMs]
    if let cursor {
      conds.append("(e.ts < ? OR (e.ts = ? AND e.id < ?))")
      args += [cursor.ts, cursor.ts, cursor.id]
    }
    return (whereClause(conds) + " ORDER BY e.ts DESC, e.id DESC", args)
  }

  public func count(_ query: ActivityQuery = ActivityQuery()) throws -> Int {
    let (conds, args) = Self.conditions(query)
    return Int(
      try rows("SELECT COUNT(*) FROM event e" + Self.whereClause(conds), args) { $0.int(0) ?? 0 }
        .first ?? 0)
  }

  public func countByTier() throws -> [ActivityTier: Int] {
    var out: [ActivityTier: Int] = [:]
    let counts = try rows("SELECT tier, COUNT(*) FROM event GROUP BY tier", []) {
      ($0.int(0) ?? 0, $0.int(1) ?? 0)
    }
    for (tier, n) in counts {
      if let t = ActivityTier(rawValue: Int(tier)) { out[t] = Int(n) }
    }
    return out
  }

  public func event(uid: String) throws -> ActivityEvent? {
    try rows("SELECT \(Self.columns) FROM event e WHERE e.uid = ?", [uid]) { Self.event($0) }.first
  }

  public func snapshot(uid: String) throws -> Data? {
    try rows("SELECT data FROM snapshot WHERE event_uid = ?", [uid]) { $0.blob(0) }.first.flatMap {
      $0
    }
  }

  public func content(uid: String) throws -> [ActivityContent] {
    try rows(
      "SELECT field, before_txt, after_txt FROM content WHERE event_uid = ? ORDER BY field", [uid]
    ) {
      ActivityContent(field: $0.text(0) ?? "", before: $0.text(1), after: $0.text(2))
    }
  }

  /// Which of these events have an `undo_of` row pointing at them.
  public func undone(among uids: [String]) throws -> Set<String> {
    var out = Set<String>()
    for chunk in stride(from: 0, to: uids.count, by: 400).map({
      Array(uids[$0..<min($0 + 400, uids.count)])
    }) {
      let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      out.formUnion(
        try rows("SELECT DISTINCT undo_of FROM event WHERE undo_of IN (\(marks))", chunk) {
          $0.text(0)
        }.compactMap { $0 })
    }
    return out
  }

  /// How many of these uids are stored (used to check an import).
  public func existingCount(uids: [String]) throws -> Int {
    var n = 0
    for chunk in stride(from: 0, to: uids.count, by: 400).map({
      Array(uids[$0..<min($0 + 400, uids.count)])
    }) {
      let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      n += Int(
        try rows("SELECT COUNT(*) FROM event WHERE uid IN (\(marks))", chunk) { $0.int(0) ?? 0 }
          .first ?? 0)
    }
    return n
  }

  public func rollups(day: Int? = nil) throws -> [(
    day: Int, kind: String, actor: String, n: Int, sumMs: Int
  )] {
    let sql =
      "SELECT day, kind, actor, n, sum_ms FROM rollup_daily" + (day == nil ? "" : " WHERE day = ?")
      + " ORDER BY day, kind, actor"
    return try rows(sql, day.map { [$0] } ?? []) {
      (
        Int($0.int(0) ?? 0), $0.text(1) ?? "", $0.text(2) ?? "", Int($0.int(3) ?? 0),
        Int($0.int(4) ?? 0)
      )
    }
  }

  /// Every event, oldest first, in batches, with snapshots and content rows. For export; memory stays at one batch.
  public func export(batchSize: Int = 500, _ body: ([ActivityEvent]) throws -> Void) throws {
    var lastID: Int64 = 0
    while true {
      var batch = try rows(
        "SELECT \(Self.columns) FROM event e WHERE e.id > ? ORDER BY e.id LIMIT ?",
        [lastID, batchSize]
      ) { Self.event($0) }
      guard let first = batch.first?.rowID, let last = batch.last?.rowID else { return }
      let lo = first
      let hi = last
      let snapshots = try rows(
        "SELECT event_uid, data FROM snapshot WHERE event_uid IN (SELECT uid FROM event WHERE id BETWEEN ? AND ?)",
        [lo, hi]
      ) { ($0.text(0) ?? "", $0.blob(1)) }
      let snapshotByUID = Dictionary(
        snapshots.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
      let contents = try rows(
        "SELECT event_uid, field, before_txt, after_txt FROM content WHERE event_uid IN (SELECT uid FROM event WHERE id BETWEEN ? AND ?)",
        [lo, hi]
      ) {
        (
          $0.text(0) ?? "",
          ActivityContent(field: $0.text(1) ?? "", before: $0.text(2), after: $0.text(3))
        )
      }
      let contentByUID = Dictionary(grouping: contents, by: \.0).mapValues { $0.map(\.1) }
      for i in batch.indices {
        batch[i].snapshot = snapshotByUID[batch[i].uid] ?? nil
        batch[i].content = contentByUID[batch[i].uid] ?? []
      }
      try body(batch)
      lastID = last
      if batch.count < batchSize { return }
    }
  }

  public func meta(_ key: String) throws -> String? {
    try rows("SELECT value FROM meta WHERE key = ?", [key]) { $0.text(0) }.first.flatMap { $0 }
  }

  public func setMeta(_ key: String, _ value: String?) throws {
    if let value {
      try exec(
        "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        [key, value])
    } else {
      try exec("DELETE FROM meta WHERE key = ?", [key])
    }
  }

  /// The size of the database file on disk (0 for memory).
  public func fileSize() -> Int64 {
    guard case .file(let url) = location else { return 0 }
    var total: Int64 = 0
    for suffix in ["", "-wal"] {
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
      total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
    return total
  }

  public func diagnostics() -> ActivityDiagnostics {
    let fts5 = (try? exec("CREATE VIRTUAL TABLE temp.fts5_probe USING fts5(x)")) != nil
    _ = try? exec("DROP TABLE IF EXISTS temp.fts5_probe")
    let json =
      (try? rows("SELECT json_extract('{\"a\":1}', '$.a')", []) { $0.int(0) })?.first != nil
    let mode = (try? rows("PRAGMA journal_mode", []) { $0.text(0) })?.first.flatMap { $0 } ?? "?"
    return ActivityDiagnostics(
      sqliteVersion: String(cString: sqlite3_libversion()), fts5: fts5, json: json,
      journalMode: mode)
  }

  /// `EXPLAIN QUERY PLAN` text for a page query (tests check that it uses an index).
  public func plan(for query: ActivityQuery, after cursor: ActivityCursor? = nil) throws -> String {
    var (conds, args) = Self.conditions(query)
    if let cursor {
      conds.append("(e.ts < ? OR (e.ts = ? AND e.id < ?))")
      args += [cursor.ts, cursor.ts, cursor.id]
    }
    let sql =
      "EXPLAIN QUERY PLAN SELECT e.id FROM event e" + Self.whereClause(conds)
      + " ORDER BY e.ts DESC, e.id DESC LIMIT 150"
    return try rows(sql, args) { $0.text(3) ?? "" }.joined(separator: "\n")
  }

  // MARK: Query building

  private static let columns = """
    e.id, e.uid, e.device, e.ts, e.tz, e.day, e.tier, e.kind, e.actor, e.channel, e.session, e.thread, e.subject_kind, \
    e.subject_ref, e.approval, e.undo_of, e.title, e.before_txt, e.after_txt, e.before_ts, e.after_ts, e.props, e.v, e.sync, \
    EXISTS (SELECT 1 FROM snapshot s WHERE s.event_uid = e.uid)
    """

  private static func whereClause(_ conds: [String]) -> String {
    conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
  }

  private static func conditions(_ q: ActivityQuery) -> ([String], [Any?]) {
    var conds: [String] = []
    var args: [Any?] = []
    if !q.tiers.isEmpty {
      conds.append("e.tier IN (" + q.tiers.map { String($0.rawValue) }.joined(separator: ",") + ")")
    }
    switch q.actors {
    case .all: break
    case .you: conds.append("e.actor = 'you'")
    case .ai: conds.append("e.actor = 'ai'")
    case .others: conds.append("e.actor NOT IN ('you', 'ai')")
    }
    if let since = q.sinceMs {
      conds.append("e.ts >= ?")
      args.append(since)
    }
    if let ref = q.subjectRef {
      conds.append("e.subject_ref = ?")
      args.append(ref)
    }
    if !q.kinds.isEmpty {
      conds.append(
        "e.kind IN (" + Array(repeating: "?", count: q.kinds.count).joined(separator: ",") + ")")
      args += q.kinds
    }
    if let text = q.search?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "%", with: "\\%"
      )
      .replacingOccurrences(of: "_", with: "\\_")
      conds.append(
        "(e.title LIKE ? ESCAPE '\\' OR e.before_txt LIKE ? ESCAPE '\\' OR e.after_txt LIKE ? ESCAPE '\\')"
      )
      args += Array(repeating: "%" + escaped + "%", count: 3)
    }
    return (conds, args)
  }

  private static func event(_ r: Row) -> ActivityEvent {
    var e = ActivityEvent(
      persistedUID: r.text(1) ?? "", ts: r.int(3) ?? 0,
      tz: Int(r.int(4) ?? 0), day: Int(r.int(5) ?? 0),
      tier: ActivityTier(rawValue: Int(r.int(6) ?? 4)), kind: r.text(7) ?? "",
      actor: r.text(8) ?? "")
    e.rowID = r.int(0)
    e.device = r.text(2) ?? ""
    e.channel = r.text(9)
    e.session = r.text(10)
    e.thread = r.text(11)
    e.subjectKind = r.text(12)
    e.subjectRef = r.text(13)
    e.approval = r.text(14)
    e.undoOf = r.text(15)
    e.title = r.text(16)
    e.beforeText = r.text(17)
    e.afterText = r.text(18)
    e.beforeTs = r.int(19)
    e.afterTs = r.int(20)
    e.props = r.text(21) ?? "{}"
    e.v = Int(r.int(22) ?? 1)
    e.sync = Int(r.int(23) ?? 0)
    e.hasSnapshot = (r.int(24) ?? 0) != 0
    return e
  }

  // MARK: SQLite plumbing

  /// A prepared statement. Binds `String`, `Int`, `Int64`, `Data`, `Double` and `nil` (NULL).
  private final class Statement {
    let handle: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
      var h: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &h, nil) == SQLITE_OK, let h else {
        throw ActivityStoreError.sql(String(cString: sqlite3_errmsg(db)) + " in: " + sql.prefix(80))
      }
      handle = h
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ args: [Any?]) {
      sqlite3_reset(handle)
      sqlite3_clear_bindings(handle)
      for (i, arg) in args.enumerated() {
        let n = Int32(i + 1)
        switch arg {
        case nil: sqlite3_bind_null(handle, n)
        case let v as String: sqlite3_bind_text(handle, n, v, -1, ActivityStore.transient)
        case let v as Int: sqlite3_bind_int64(handle, n, Int64(v))
        case let v as Int64: sqlite3_bind_int64(handle, n, v)
        case let v as Double: sqlite3_bind_double(handle, n, v)
        case let v as Data:
          v.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(
              handle, n, raw.baseAddress, Int32(v.count), ActivityStore.transient)
          }
        default: sqlite3_bind_null(handle, n)
        }
      }
    }

    /// Runs a statement that returns no rows.
    func run(_ args: [Any?]) throws {
      bind(args)
      let rc = sqlite3_step(handle)
      guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
        throw ActivityStoreError.sql(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
      }
    }
  }

  /// One result row, valid inside the `rows` closure only.
  public struct Row {
    fileprivate let stmt: OpaquePointer

    public func text(_ i: Int32) -> String? {
      guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else {
        return nil
      }
      return String(cString: c)
    }

    public func int(_ i: Int32) -> Int64? {
      sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
    }

    public func blob(_ i: Int32) -> Data? {
      guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_blob(stmt, i) else {
        return nil
      }
      return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
  }

  private func exec(_ sql: String, _ args: [Any?] = []) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let db else { throw ActivityStoreError.open("closed") }
    if args.isEmpty {
      var err: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
        let message = err.map { String(cString: $0) } ?? "sqlite error"
        sqlite3_free(err)
        throw ActivityStoreError.sql(message)
      }
    } else {
      try Statement(db, sql).run(args)
    }
  }

  /// Runs a statement and returns how many rows it changed.
  private func execCount(_ sql: String, _ args: [Any?]) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    try exec(sql, args)
    return Int(sqlite3_changes(db))
  }

  private func rows<T>(_ sql: String, _ args: [Any?] = [], _ read: (Row) -> T) throws -> [T] {
    lock.lock()
    defer { lock.unlock() }
    guard let db else { throw ActivityStoreError.open("closed") }
    let s = try Statement(db, sql)
    s.bind(args)
    var out: [T] = []
    while true {
      let rc = sqlite3_step(s.handle)
      if rc == SQLITE_ROW {
        out.append(read(Row(stmt: s.handle)))
      } else if rc == SQLITE_DONE {
        return out
      } else {
        throw ActivityStoreError.sql(String(cString: sqlite3_errmsg(db)))
      }
    }
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let nested = sqlite3_get_autocommit(db) == 0
    if nested { return try body() }
    try exec("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try exec("COMMIT")
      return value
    } catch {
      _ = try? exec("ROLLBACK")
      throw error
    }
  }
}

import Foundation
import TodayCore
import TodayShared

// Pure data types for the Activity data store (see docs/research/activity-data-store.md). No SwiftData, no SwiftUI, no SQLite:
// they compile into the `OneLogic` SPM target and run under `swift test`. The SQLite file is `ActivityStore.swift`, the buffer
// in front of it `ActivityRecorder.swift`, the ledger bridge `ActivityLedger.swift`.
//
// One row = one immutable event. Rows carry a UUID and a device id so that a later sync (CloudKit) can merge them by union.
// Text that is personal content (task titles, before/after, edited-card diffs) lives in its own fields (`title`, `beforeText`,
// `afterText`, `content`, `snapshot`), never inside `props`, so a redaction pass can drop it in one step (`redacted()`).

/// How close to the user's own data a record is: 1 changes, 2 AI decisions, 3 usage, 4 system.
public enum ActivityTier: Int, CaseIterable, Identifiable, Codable {
  case changes = 1
  case ai, usage, system
  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .changes: "Changes"
    case .ai: "AI conversation and decisions"
    case .usage: "Usage"
    case .system: "System"
    }
  }

  /// One sentence for the Settings page: what is recorded in this category.
  public var detail: String {
    switch self {
    case .changes:
      "Who added, moved, completed or deleted what, and how it was approved. This is the Activity screen, and Undo uses it."
    case .ai:
      "Which cards the AI showed, whether you added, edited or dropped them, and which suggestions you tapped. No chat text unless you switch that on."
    case .usage:
      "Which screens you open and how long a quick add takes. No titles and no search text."
    case .system:
      "Things that happen around the app: Share imports, Shortcuts runs, alarm stops, sync conflicts and errors."
    }
  }
}

/// Event kinds. A kind is `<family>.<name>`; the family says the tier.
public enum ActivityKind {
  // Tier 1: the ledger. `change.<LedgerAction>`; grants are `grant.granted` / `grant.revoked`.
  public static let changePrefix = "change."
  public static let grantPrefix = "grant."
  // Tier 2
  public static let aiTurn = "ai.turn"
  public static let aiCardShown = "ai.card.shown"
  public static let aiCardResolved = "ai.card.resolved"
  public static let aiUndo = "ai.undo"
  // Tier 3
  public static let uiScreenOpen = "ui.screen.open"
  public static let uiQuickAddCommit = "ui.quickadd.commit"
  // Tier 4
  public static let sysShareAdd = "sys.share.add"
  public static let sysShareImport = "sys.share.import"
  public static let sysWidgetRefresh = "sys.widget.refresh"
  public static let sysIntentRun = "sys.intent.run"
  public static let sysSyncConflict = "sys.sync.conflict"
  public static let sysError = "sys.error"
  /// An alarm's Stop was tapped (AlarmKit's stop intent); `subject_ref` is the AlarmKit id, `title` the label.
  public static let sysAlarmStopped = "sys.alarm.stopped"

  /// The tier a kind belongs to; unknown kinds are system events.
  public static func tier(of kind: String) -> ActivityTier {
    if kind.hasPrefix("change.") || kind.hasPrefix("grant.") { return .changes }
    if kind.hasPrefix("ai.") { return .ai }
    if kind.hasPrefix("ui.") { return .usage }
    return .system
  }
}

/// Text that must stay redactable on its own: the user's words before and after an edit of an AI card.
public struct ActivityContent: Equatable {
  public init(field: String, before: String? = nil, after: String? = nil) {
    self.field = field
    self.before = before
    self.after = after
  }
  /// "title", "when", "list", "kind", "repeat", "input" ...
  public var field: String
  public var before: String?
  public var after: String?
}

public struct ActivityEvent: Equatable, Identifiable {
  public var id: String { uid }

  public var uid: String
  /// Random id of this install; filled in by the recorder when empty.
  public var device: String = ""
  /// Unix milliseconds, UTC.
  public var ts: Int64
  /// Minutes east of UTC when written.
  public var tz: Int = 0
  /// Local yyyymmdd when written, so grouping survives a time-zone change.
  public var day: Int = 0
  public var tier: Int
  public var kind: String
  /// you | ai | siri | shortcut | share | agent:<name> | system
  public var actor: String
  /// app | ask | automatic | intent | share | notification | sync | widget
  public var channel: String?
  /// One id per app launch; filled in by the recorder when empty.
  public var session: String?
  /// `ChatThread.id` (a reference, never a copy of the text).
  public var thread: String?
  /// task | event | alarm | grant
  public var subjectKind: String?
  public var subjectRef: String?
  /// asked | auto | user | observed
  public var approval: String?
  public var undoOf: String?
  public var title: String?
  public var beforeText: String?
  public var afterText: String?
  public var beforeTs: Int64?
  public var afterTs: Int64?
  /// JSON object text, no free text. Shape depends on (kind, v). Build it with `ActivityProps`.
  public var props: String = "{}"
  public var v: Int = 1
  /// 0 = local only; reserved for the CloudKit phase.
  public var sync: Int = 0

  /// A deleted reminder (`TaskSnapshot` JSON), kept so Activity can put it back. Stored in its own table.
  public var snapshot: Data?
  /// Edited-card diffs. Stored in their own table.
  public var content: [ActivityContent] = []

  // Read side only (set by the store when it loads a row).
  public var rowID: Int64?
  public var hasSnapshot = false

  public init(
    kind: String, tier: ActivityTier? = nil, actor: String, channel: String? = nil,
    at date: Date = .now,
    calendar: Calendar = .current, props: String = "{}"
  ) {
    self.uid = UUID().uuidString
    let stamp = ActivityClock.stamp(date, calendar: calendar)
    self.ts = stamp.ts
    self.tz = stamp.tz
    self.day = stamp.day
    self.tier = (tier ?? ActivityKind.tier(of: kind)).rawValue
    self.kind = kind
    self.actor = actor
    self.channel = channel
    self.props = props
  }

  /// Read-side envelope: persisted identity and local time need no new UUID or calendar stamp.
  /// The store owns SQLite coercion and fallbacks; optional payload fields keep their usual empty defaults.
  public init(
    persistedUID uid: String, ts: Int64, tz: Int, day: Int, tier: ActivityTier?, kind: String,
    actor: String
  ) {
    self.uid = uid
    self.ts = ts
    self.tz = tz
    self.day = day
    self.tier = (tier ?? ActivityKind.tier(of: kind)).rawValue
    self.kind = kind
    self.actor = actor
  }

  public var date: Date { ActivityClock.date(ms: ts) }
  public var tierValue: ActivityTier { ActivityTier(rawValue: tier) ?? .system }

  /// Everything personal removed, time coarsened to the hour: the shape a later "share anonymous counters" upload would use.
  public func redacted() -> ActivityEvent {
    var e = self
    e.title = nil
    e.beforeText = nil
    e.afterText = nil
    e.thread = nil
    e.subjectRef = nil
    e.undoOf = nil
    e.snapshot = nil
    e.content = []
    e.beforeTs = nil
    e.afterTs = nil
    e.ts = (ts / 3_600_000) * 3_600_000
    e.device = ""
    e.session = nil
    e.uid = ""
    return e
  }
}

public enum ActivityClock {
  /// (unix ms, minutes east of UTC, local yyyymmdd) for a moment.
  public static func stamp(_ date: Date, calendar: Calendar = .current) -> (
    ts: Int64, tz: Int, day: Int
  ) {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    let day = (c.year ?? 1970) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    return (ms(date), calendar.timeZone.secondsFromGMT(for: date) / 60, day)
  }

  public static func ms(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
  public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// `props` is JSON text. These helpers build and read it without every call site touching JSONSerialization.
public enum ActivityProps {
  public static func json(_ values: [String: Any]) -> String {
    let clean = values.filter { JSONSerialization.isValidJSONObject([$0.key: $0.value]) }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  public static func dictionary(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }
}

// MARK: JSON Lines (export, outbox and the future sync payload)

/// One event per line, snake_case keys as in the table, `props` as a nested object. Unknown keys are ignored when reading, so
/// new fields never break old readers. `snapshot` is base64.
public enum ActivityJSONL {
  public static func line(_ e: ActivityEvent) -> String {
    var o: [String: Any] = [
      "uid": e.uid, "device": e.device, "ts": e.ts, "tz": e.tz, "day": e.day, "tier": e.tier,
      "kind": e.kind, "actor": e.actor, "v": e.v, "props": ActivityProps.dictionary(e.props),
    ]
    func put(_ key: String, _ value: Any?) { if let value { o[key] = value } }
    put("channel", e.channel)
    put("session", e.session)
    put("thread", e.thread)
    put("subject_kind", e.subjectKind)
    put("subject_ref", e.subjectRef)
    put("approval", e.approval)
    put("undo_of", e.undoOf)
    put("title", e.title)
    put("before_txt", e.beforeText)
    put("after_txt", e.afterText)
    put("before_ts", e.beforeTs)
    put("after_ts", e.afterTs)
    if e.sync != 0 { o["sync"] = e.sync }
    if let snapshot = e.snapshot { o["snapshot"] = snapshot.base64EncodedString() }
    if !e.content.isEmpty {
      o["content"] = e.content.map { c -> [String: Any] in
        var d: [String: Any] = ["field": c.field]
        if let b = c.before { d["before"] = b }
        if let a = c.after { d["after"] = a }
        return d
      }
    }
    let data =
      (try? JSONSerialization.data(
        withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  /// nil for a line that is not a JSON object or lacks the required keys (kind, actor, ts).
  public static func event(from line: String) -> ActivityEvent? {
    guard let data = line.data(using: .utf8),
      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = o["kind"] as? String, let actor = o["actor"] as? String,
      let ts = (o["ts"] as? NSNumber)?.int64Value
    else { return nil }
    func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
    func i64(_ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }
    var e = ActivityEvent(
      kind: kind, tier: int("tier").flatMap(ActivityTier.init(rawValue:)), actor: actor,
      at: ActivityClock.date(ms: ts))
    if let uid = o["uid"] as? String, !uid.isEmpty { e.uid = uid }
    e.device = o["device"] as? String ?? ""
    e.ts = ts
    if let tz = int("tz") { e.tz = tz }
    if let day = int("day") { e.day = day }
    e.channel = o["channel"] as? String
    e.session = o["session"] as? String
    e.thread = o["thread"] as? String
    e.subjectKind = o["subject_kind"] as? String
    e.subjectRef = o["subject_ref"] as? String
    e.approval = o["approval"] as? String
    e.undoOf = o["undo_of"] as? String
    e.title = o["title"] as? String
    e.beforeText = o["before_txt"] as? String
    e.afterText = o["after_txt"] as? String
    e.beforeTs = i64("before_ts")
    e.afterTs = i64("after_ts")
    if let props = o["props"] as? [String: Any] { e.props = ActivityProps.json(props) }
    if let v = int("v") { e.v = v }
    e.sync = int("sync") ?? 0
    if let b64 = o["snapshot"] as? String { e.snapshot = Data(base64Encoded: b64) }
    if let list = o["content"] as? [[String: Any]] {
      e.content = list.compactMap { d in
        (d["field"] as? String).map {
          ActivityContent(field: $0, before: d["before"] as? String, after: d["after"] as? String)
        }
      }
    }
    return e
  }

  /// Parses a whole file; lines that do not parse are skipped (a half-written line never blocks the rest).
  public static func events(from text: String) -> [ActivityEvent] {
    text.split(whereSeparator: \.isNewline).compactMap { event(from: String($0)) }
  }
}

// MARK: CSV (export for humans)

/// RFC 4180: fields with a comma, quote or line break are quoted, quotes are doubled, rows end with CRLF. Flat envelope columns,
/// `props` as one JSON cell. Snapshots and edited-card diffs are only in the JSONL export.
public enum ActivityCSV {
  public static let columns = [
    "uid", "time", "ts", "tz", "day", "tier", "kind", "actor", "channel", "approval",
    "subject_kind",
    "subject_ref", "thread", "session", "device", "title", "before_txt", "after_txt", "before_ts",
    "after_ts", "undo_of", "v", "props",
  ]

  public static var header: String { row(columns) }

  public static func row(_ event: ActivityEvent) -> String {
    row([
      event.uid, localTime(event), String(event.ts), String(event.tz), String(event.day),
      String(event.tier), event.kind,
      event.actor, event.channel ?? "", event.approval ?? "", event.subjectKind ?? "",
      event.subjectRef ?? "",
      event.thread ?? "", event.session ?? "", event.device, event.title ?? "",
      event.beforeText ?? "",
      event.afterText ?? "", event.beforeTs.map(String.init) ?? "",
      event.afterTs.map(String.init) ?? "",
      event.undoOf ?? "", String(event.v), event.props,
    ])
  }

  public static func row(_ fields: [String]) -> String {
    fields.map(field).joined(separator: ",") + "\r\n"
  }

  public static func field(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
      return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// ISO 8601 in the time zone the event was written in, e.g. 2026-10-12T09:41:03+08:00.
  public static func localTime(_ event: ActivityEvent) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: event.tz * 60) ?? .gmt
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: event.date)
  }
}

// MARK: Settings, retention

/// Forever keeps raw events in every tier. Finite choices limit changes (tier 1); other tiers use fixed windows.
public enum ActivityRetention: String, CaseIterable, Identifiable, Sendable {
  case days90 = "90d"
  case year = "1y"
  case forever
  public var id: Self { self }

  public static let `default`: ActivityRetention = .forever

  public var title: String {
    switch self {
    case .days90: "90 days"
    case .year: "1 year"
    case .forever: "Forever"
    }
  }

  public var days: Int? {
    switch self {
    case .days90: 90
    case .year: 365
    case .forever: nil
    }
  }

  /// Changes before this moment are dropped by `prune`; nil keeps raw events in every tier.
  public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
    days.flatMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now)) }
  }
}

/// The fixed windows of the other tiers (document §2.3).
public enum ActivityWindows {
  /// Undo snapshots of deleted reminders are kept this long; Undo from Activity stops being offered after it.
  public static let snapshotDays = 30
  public static let aiDays = 180
  public static let usageDays = 30
  public static let systemDays = 90

  public static func cutoffMs(days: Int, now: Date, calendar: Calendar = .current) -> Int64 {
    let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
    return ActivityClock.ms(day)
  }
}

/// What the user switched on or off. Read from `UserDefaults` so the pure recorder can be tested with a throwaway suite.
public struct ActivitySettings: Equatable {
  public var paused = false
  public var tiers: Set<ActivityTier> = Set(ActivityTier.allCases)
  public var retention: ActivityRetention = .default
  /// Keep the text of a chat message next to its `ai.turn` event (in the `content` table). On by default: the user's own
  /// history, on this device only, is what makes the Activity data useful for improving the product later.
  public var keepChatText = true

  public static let pausedKey = "activity.setting.paused"
  public static let retentionKey = "activity.setting.retention"
  public static let keepChatTextKey = "activity.setting.keepChatText"
  public static func tierKey(_ tier: ActivityTier) -> String {
    "activity.setting.tier.\(tier.rawValue)"
  }

  public init() {}

  public init(_ defaults: UserDefaults) {
    paused = defaults.bool(forKey: Self.pausedKey)
    tiers = Set(
      ActivityTier.allCases.filter { defaults.object(forKey: Self.tierKey($0)) as? Bool ?? true })
    retention =
      defaults.string(forKey: Self.retentionKey).flatMap(ActivityRetention.init(rawValue:))
      ?? .default
    keepChatText = defaults.object(forKey: Self.keepChatTextKey) as? Bool ?? true
  }

  public func save(to defaults: UserDefaults) {
    defaults.set(paused, forKey: Self.pausedKey)
    for t in ActivityTier.allCases { defaults.set(tiers.contains(t), forKey: Self.tierKey(t)) }
    defaults.set(retention.rawValue, forKey: Self.retentionKey)
    defaults.set(keepChatText, forKey: Self.keepChatTextKey)
  }

  /// Whether events of this tier are kept right now (pause switches every tier off).
  public func records(_ tier: ActivityTier) -> Bool { !paused && tiers.contains(tier) }
}

/// The wording the app uses about the activity data, in one place (Settings page and the Activity screen).
public enum ActivityNote {
  public static let whereStored =
    "Stored only on this iPhone, in a private database file inside Today. It is not synced or uploaded."
  public static let screenLine =
    "Everything here is stored only on this iPhone. Settings → Activity data has pause, clear and export."
  public static let neverRecorded =
    "Never recorded: passwords, and the text of your chats or searches (unless you switch chat text on)."
}

import Foundation
import TodayCore
import TodayShared

// The changes ledger (tier 1) on top of the Activity store. Pure: no SwiftData. `Ledger.swift` records through these types and
// reads the Activity screen's rows back as `LedgerItem`s. See docs/research/activity-data-store.md §3.6 for the migration plan.

/// One line of the Activity ledger as the app sees it (what `LedgerEntry` used to hold): who changed what, how, when,
/// before → after, and how it was approved. Immutable once stored; Undo adds an `undone` item pointing at the original.
public struct LedgerItem: Identifiable, Equatable {
  public var id: UUID
  public var date: Date
  /// `LedgerActor.raw`.
  public var actor: String
  /// `LedgerChannel.rawValue`.
  public var channel: String
  /// `LedgerAction.rawValue`.
  public var action: String
  /// "task", "event", "alarm" or "grant".
  public var itemKind: String
  /// The reminder's `PersistentIdentifier` (JSON), filled in once it is saved. nil for events, alarms and deletes.
  public var itemRef: String?
  public var title: String
  public var before: String
  public var after: String
  /// `LedgerApproval.rawValue`.
  public var approval: String
  /// The date before → after (a reminder's due date). A completion carries the due date it had; a deleted calendar event
  /// carries its start and end, so a past day can still show it (`DayHistory`).
  public var beforeDate: Date?
  public var afterDate: Date?
  /// A deleted reminder is stored (`TaskSnapshot`), so Activity can put it back.
  public var hasSnapshot = false
  public var undoOf: UUID?

  public init(
    id: UUID = UUID(), date: Date = .now, actor: LedgerActor, channel: LedgerChannel,
    action: LedgerAction, itemKind: String,
    title: String, before: String = "", after: String = "", approval: LedgerApproval
  ) {
    self.id = id
    self.date = date
    self.actor = actor.raw
    self.channel = channel.rawValue
    self.action = action.rawValue
    self.itemKind = itemKind
    self.title = title
    self.before = before
    self.after = after
    self.approval = approval.rawValue
  }

  public var actorValue: LedgerActor { LedgerActor(raw: actor) }
  public var actionValue: LedgerAction { LedgerAction(rawValue: action) ?? .moved }
  public var approvalValue: LedgerApproval { LedgerApproval(rawValue: approval) ?? .userMade }
}

extension LedgerItem {
  /// The event that stores this item. `snapshot` goes to its own table.
  public func event(snapshot: Data? = nil, calendar: Calendar = .current) -> ActivityEvent {
    let isGrant = actionValue == .granted || actionValue == .revoked
    let kind = (isGrant ? ActivityKind.grantPrefix : ActivityKind.changePrefix) + action
    var e = ActivityEvent(
      kind: kind, tier: .changes, actor: actor,
      channel: (LedgerChannel(rawValue: channel) ?? .app).slug,
      at: date, calendar: calendar)
    e.uid = id.uuidString
    e.subjectKind = itemKind
    e.subjectRef = itemRef
    e.approval = approval
    e.undoOf = undoOf?.uuidString
    e.title = title
    e.beforeText = before
    e.afterText = after
    e.beforeTs = beforeDate.map(ActivityClock.ms)
    e.afterTs = afterDate.map(ActivityClock.ms)
    e.snapshot = snapshot
    return e
  }

  /// A stored tier-1 event back as a ledger item.
  public init(event e: ActivityEvent) {
    let name =
      e.kind.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? e.kind
    self.id = UUID(uuidString: e.uid) ?? UUID()
    self.date = e.date
    self.actor = e.actor
    self.channel =
      e.channel.flatMap(LedgerChannel.init(slug:))?.rawValue ?? LedgerChannel.app.rawValue
    self.action = name
    self.itemKind = e.subjectKind ?? "task"
    self.itemRef = e.subjectRef
    self.title = e.title ?? ""
    self.before = e.beforeText ?? ""
    self.after = e.afterText ?? ""
    self.approval = e.approval ?? LedgerApproval.userMade.rawValue
    self.beforeDate = e.beforeTs.map(ActivityClock.date(ms:))
    self.afterDate = e.afterTs.map(ActivityClock.date(ms:))
    self.hasSnapshot = e.hasSnapshot
    self.undoOf = e.undoOf.flatMap(UUID.init(uuidString:))
  }
}

/// An old SwiftData `LedgerEntry` as plain values, so the import can be tested without SwiftData.
public struct LegacyLedgerRow: Equatable {
  public init(
    id: UUID, date: Date, actor: String, channel: String, action: String, itemKind: String,
    itemRef: String? = nil, title: String, before: String, after: String, approval: String,
    beforeDate: Date? = nil, afterDate: Date? = nil, snapshot: Data? = nil, undoOf: UUID? = nil
  ) {
    self.id = id
    self.date = date
    self.actor = actor
    self.channel = channel
    self.action = action
    self.itemKind = itemKind
    self.itemRef = itemRef
    self.title = title
    self.before = before
    self.after = after
    self.approval = approval
    self.beforeDate = beforeDate
    self.afterDate = afterDate
    self.snapshot = snapshot
    self.undoOf = undoOf
  }
  public var id: UUID
  public var date: Date
  public var actor: String
  public var channel: String
  public var action: String
  public var itemKind: String
  public var itemRef: String?
  public var title: String
  public var before: String
  public var after: String
  public var approval: String
  public var beforeDate: Date?
  public var afterDate: Date?
  public var snapshot: Data?
  public var undoOf: UUID?

  public var item: LedgerItem {
    var i = LedgerItem(
      id: id, date: date, actor: LedgerActor(raw: actor),
      channel: LedgerChannel(rawValue: channel) ?? .app,
      action: LedgerAction(rawValue: action) ?? .moved, itemKind: itemKind, title: title,
      before: before,
      after: after, approval: LedgerApproval(rawValue: approval) ?? .userMade)
    // Keep the stored strings exactly (an unknown action or channel is not rewritten).
    i.action = action
    i.channel = channel
    i.approval = approval
    i.actor = actor
    i.itemRef = itemRef
    i.beforeDate = beforeDate
    i.afterDate = afterDate
    i.undoOf = undoOf
    i.hasSnapshot = snapshot != nil
    return i
  }

  public var event: ActivityEvent { item.event(snapshot: snapshot) }
}

/// The one-time copy of the old ledger into the store (document §3.6 step 2). Idempotent: keyed on the entry's UUID, so running
/// it twice, or after a crash half way, adds nothing twice. Nothing in SwiftData is deleted here.
public enum LedgerImport {
  public static let migratedKey = "ledger_migrated"
  /// The launch session in which the copy was verified; the old rows are removed only in a later session.
  public static let migratedSessionKey = "ledger_migrated_session"
  public static let legacyRemovedKey = "ledger_legacy_removed"

  public struct Outcome: Equatable {
    /// Rows in the old ledger.
    public var legacyTotal = 0
    /// New events added (or, in a dry run, that would be added).
    public var imported = 0
    /// Rows that were already in the store.
    public var alreadyThere = 0
    /// Every old row is now in the store.
    public var verified = false
  }

  /// Copies the old rows in batches, one transaction each. `fetch(offset, limit)` returns old rows in a stable order.
  /// With `dryRun` nothing is written: the outcome says what would happen.
  public static func run(
    into store: ActivityStore, total: Int, session: String, batch: Int = 500, dryRun: Bool = false,
    fetch: (_ offset: Int, _ limit: Int) -> [LegacyLedgerRow]
  ) throws -> Outcome {
    var out = Outcome(legacyTotal: total)
    var offset = 0
    while offset < total {
      let rows = fetch(offset, batch)
      if rows.isEmpty { break }
      offset += rows.count
      let there = try store.existingCount(uids: rows.map { $0.id.uuidString })
      out.alreadyThere += there
      if dryRun {
        out.imported += rows.count - there
      } else {
        out.imported += try store.insert(rows.map(\.event))
      }
    }
    out.verified = !dryRun && out.imported + out.alreadyThere == total
    if out.verified {
      try store.setMeta(migratedKey, "1")
      try store.setMeta(migratedSessionKey, session)
    }
    return out
  }

  public static func isMigrated(_ store: ActivityStore) -> Bool {
    (try? store.meta(migratedKey)) == "1"
  }

  /// The old rows may be deleted: the copy was verified in an earlier launch than this one, and that has not happened yet.
  public static func mayRemoveLegacy(_ store: ActivityStore, session: String) -> Bool {
    guard isMigrated(store), (try? store.meta(legacyRemovedKey)) != "1" else { return false }
    guard let at = try? store.meta(migratedSessionKey) else { return false }
    return at != session
  }
}

import Foundation
import TodayCore
import TodayShared

// The changes ledger (tier 1) on top of the Activity store. Pure: no SwiftData. `Ledger.swift` records through these types and
// reads the Activity screen's rows back as `LedgerItem`s. See docs/research/activity-data-store.md §3.6 for the migration plan.

/// One line of the Activity ledger as the app sees it: who changed what, how, when,
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

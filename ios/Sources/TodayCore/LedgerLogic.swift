import Foundation

// Pure logic for the Activity ledger, with no SwiftData/SwiftUI, so it can be unit-tested with `swift test` (see ios/Eval).
// The SwiftData model and the recording helpers are in `Ledger.swift`; the screen is `ActivityView.swift`.

/// Who made a change: you, Today's AI, Siri, a Shortcut, the Share sheet, or another app or agent (by name).
public enum LedgerActor: Hashable {
  case you, todayAI, siri, shortcut, share
  case agent(String)

  /// What is stored: "you", "ai", "siri", "shortcut", "share" or "agent:<name>".
  public var raw: String {
    switch self {
    case .you: "you"
    case .todayAI: "ai"
    case .siri: "siri"
    case .shortcut: "shortcut"
    case .share: "share"
    case .agent(let name): "agent:" + name
    }
  }

  public init(raw: String) {
    switch raw {
    case "you": self = .you
    case "ai": self = .todayAI
    case "siri": self = .siri
    case "shortcut": self = .shortcut
    case "share": self = .share
    default: self = .agent(raw.hasPrefix("agent:") ? String(raw.dropFirst(6)) : raw)
    }
  }

  public var name: String {
    switch self {
    case .you: "You"
    case .todayAI: "Today AI"
    case .siri: "Siri"
    case .shortcut: "Shortcuts"
    case .share: "Share"
    case .agent(let name): name
    }
  }

  /// SF Symbol for the row.
  public var symbol: String {
    switch self {
    case .you: "person.fill"
    case .todayAI: "sparkles"
    case .siri: "waveform"
    case .shortcut: "square.2.layers.3d"
    case .share: "square.and.arrow.up"
    case .agent(let name):
      name.hasPrefix("Apple") ? "arrow.triangle.2.circlepath" : "cpu"
    }
  }

  /// Which Activity filter chip shows it. Everything that is neither you nor Today AI counts as an agent.
  public var filter: ActivityFilter {
    switch self {
    case .you: .you
    case .todayAI: .ai
    default: .agents
    }
  }
}

/// The filter chips on Activity.
public enum ActivityFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case ai = "AI"
  case you = "You"
  case agents = "Agents"
  public var id: Self { self }

  public func includes(_ actor: LedgerActor) -> Bool { self == .all || actor.filter == self }
}

/// The way a change came in.
public enum LedgerChannel: String, CaseIterable {
  case app = "Today app"
  case ask = "Ask AI"
  case automatic = "Automatic"
  case intent = "App Intent"
  case share = "Share"
  case notification = "Notification"
  case sync = "Sync"

  /// What the Activity store keeps in its `channel` column (lowercase, no spaces; the raw value above is for people).
  public var slug: String {
    switch self {
    case .app: "app"
    case .ask: "ask"
    case .automatic: "automatic"
    case .intent: "intent"
    case .share: "share"
    case .notification: "notification"
    case .sync: "sync"
    }
  }

  public init?(slug: String) {
    guard let match = Self.allCases.first(where: { $0.slug == slug }) else { return nil }
    self = match
  }
}

/// What happened.
public enum LedgerAction: String {
  case created, completed, reopened, deleted
  case settled, snoozed, restored
  /// A planned time was given to something that had none.
  case planned
  /// A planned time (or an event's start) changed.
  case moved
  case unscheduled
  /// The deadline changed (Tidy overdue).
  case redated
  case renamed
  /// Settings changed (an alarm's time, label, repeat, sound or snooze).
  case edited
  case switchedOn, switchedOff
  case undone
  case granted, revoked

  public var verb: String {
    switch self {
    case .created: "Added"
    case .completed: "Completed"
    case .reopened: "Reopened"
    case .deleted: "Deleted"
    case .settled: "Settled"
    case .snoozed: "Snoozed"
    case .restored: "Restored"
    case .planned: "Planned"
    case .moved: "Moved"
    case .unscheduled: "Unscheduled"
    case .redated: "New date for"
    case .renamed: "Renamed"
    case .edited: "Changed"
    case .switchedOn: "Turned on"
    case .switchedOff: "Turned off"
    case .undone: "Undid"
    case .granted: "Allowed"
    case .revoked: "Revoked"
    }
  }
}

/// How the change was approved.
public enum LedgerApproval: String {
  /// The user tapped Apply / Add on an AI card.
  case asked
  /// Applied by itself under a grant the user gave (retired; see `ActionPolicy`).
  case autoUnderGrant = "auto"
  /// The user did it.
  case userMade = "user"
  /// Seen during sync: made outside Today (e.g. deleted in Apple Reminders).
  case observed

  /// A short tag on the row; nil when it says nothing new.
  public var label: String? {
    switch self {
    case .asked: "Approved"
    case .autoUnderGrant: "Automatic"
    case .userMade: nil
    case .observed: "Outside Today"
    }
  }
}

/// Everything needed to put a deleted reminder back from Activity.
public struct TaskSnapshot: Codable, Equatable {
  public var title: String
  public var note: String = ""
  public var isDone = false
  public var doneAt: Date?
  public var durationMinutes = 25
  public var due: Date?
  public var createdAt = Date()
  public var reminderOffsetMinutes: Int? = 0
  public var listName = ""
  public var tags: [String] = []
  public var flagged = false
  public var repeatRule: String?
  public var checklist: [ChecklistItem] = []
  public var ringsAsAlarm = false
  public var reminderAlert: String?

  public init(
    title: String, note: String = "", isDone: Bool = false, doneAt: Date? = nil,
    durationMinutes: Int = 25, due: Date? = nil,
    createdAt: Date = Date(), reminderOffsetMinutes: Int? = 0, listName: String = "",
    tags: [String] = [], flagged: Bool = false, repeatRule: String? = nil,
    checklist: [ChecklistItem] = [], ringsAsAlarm: Bool = false, reminderAlert: String? = nil
  ) {
    self.title = title
    self.note = note
    self.isDone = isDone
    self.doneAt = doneAt
    self.durationMinutes = durationMinutes
    self.due = due
    self.createdAt = createdAt
    self.reminderOffsetMinutes = reminderOffsetMinutes
    self.listName = listName
    self.tags = tags
    self.flagged = flagged
    self.repeatRule = repeatRule
    self.checklist = checklist
    self.ringsAsAlarm = ringsAsAlarm
    self.reminderAlert = reminderAlert
  }
}

public enum LedgerFormat {
  /// Entries older than this are dropped at launch.
  public static let retentionDays = 90

  public static func retentionCutoff(now: Date, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) ?? now
  }

  /// "Planned “Buy milk”", "Allowed “Plan reminders into free time”".
  public static func headline(_ action: LedgerAction, title: String) -> String {
    "\(action.verb) “\(title)”"
  }

  /// "Not planned → Today 10:00". Empty when there is nothing to compare.
  public static func change(before: String, after: String) -> String {
    switch (before.isEmpty, after.isEmpty) {
    case (true, true): ""
    case (false, true): before
    case (true, false): after
    case (false, false): before + " → " + after
    }
  }

  /// A planned time or deadline as the ledger writes it: "Today 10:00", or "Not planned" / "No date" for nil.
  public static func time(
    _ date: Date?, none: String = "Not planned", calendar: Calendar = .current
  ) -> String {
    date.map { DayLabel.withTime($0, calendar: calendar) } ?? none
  }

  /// Activity offers Undo for changes it can put back on its own: Today's own reminders (complete, date, rename, add,
  /// delete) and alarms (add, delete, edit, on/off; each needs the snapshot taken when it changed, so old rows and rows older
  /// than the snapshot window have none). Not for Focus choices (Settle and its reverse), grants, undo records, changes seen
  /// in sync, or something already undone.
  public static func canUndo(
    action: LedgerAction, itemKind: String, approval: LedgerApproval, hasItem: Bool,
    hasSnapshot: Bool, alreadyUndone: Bool
  ) -> Bool {
    guard !alreadyUndone, approval != .observed else { return false }
    switch itemKind {
    case "task":
      switch action {
      case .deleted: return hasSnapshot
      case .completed, .reopened, .redated, .renamed, .created: return hasItem
      // Retired planned-time entries stay listed but cannot be undone: a reminder has one date now.
      default: return false
      }
    case "alarm":
      switch action {
      case .created, .deleted, .edited, .moved, .switchedOn, .switchedOff: return hasSnapshot
      default: return false
      }
    case "list":
      switch action {
      case .created, .deleted, .renamed, .edited: return hasSnapshot
      default: return false
      }
    case "event":
      // Only a delete that kept a snapshot (a one-off without attendees); moves and series deletes have none.
      return action == .deleted && hasSnapshot
    default:
      return false
    }
  }

  /// Newest first, one group per calendar day: "Today", "Yesterday", then "Wed, Oct 15".
  public static func groupByDay<T>(
    _ items: [T], date: (T) -> Date, now: Date, calendar: Calendar = .current
  )
    -> [(day: Date, title: String, items: [T])]
  {
    let sorted = items.enumerated().sorted { a, b in
      let (da, db) = (date(a.element), date(b.element))
      return da == db ? a.offset < b.offset : da > db
    }.map(\.element)
    var out: [(day: Date, title: String, items: [T])] = []
    for item in sorted {
      let day = calendar.startOfDay(for: date(item))
      if let last = out.last, last.day == day {
        out[out.count - 1].items.append(item)
      } else {
        out.append((day, dayTitle(day, now: now, calendar: calendar), [item]))
      }
    }
    return out
  }

  public static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "Today" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: y)
    {
      return "Yesterday"
    }
    return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }
}

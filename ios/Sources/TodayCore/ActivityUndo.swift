import Foundation

// What Activity keeps so it can put back a change that is not a reminder's (alarms for now), and the rules for when it
// can. Pure: no SwiftData. Stored as JSON in the Activity store's `snapshot` table, never in `props` (it holds labels).
// Snapshots are dropped after `ActivityWindows.snapshotDays` (30), which ends Undo for that row.

/// An alarm's settings as they were at one moment.
public struct AlarmSnapshot: Codable, Equatable, Sendable {
  public var hour: Int
  public var minute: Int
  public var label: String
  public var note: String
  public var weekdays: [Int]
  public var isOn: Bool
  public var snooze: Bool
  public var sound: String
  public var snoozeMinutes: Int

  public init(
    hour: Int, minute: Int, label: String = "", note: String = "", weekdays: [Int] = [],
    isOn: Bool = true, snooze: Bool = true, sound: String = "", snoozeMinutes: Int = 9
  ) {
    self.hour = hour
    self.minute = minute
    self.label = label
    self.note = note
    self.weekdays = weekdays.sorted()
    self.isOn = isOn
    self.snooze = snooze
    self.sound = sound
    self.snoozeMinutes = snoozeMinutes
  }
}

/// One alarm change: the settings before (nil when it was added) and after (nil when it was deleted).
/// Which alarm it was is the ledger row's `subject_ref`.
public struct AlarmChange: Codable, Equatable, Sendable {
  public var before: AlarmSnapshot?
  public var after: AlarmSnapshot?
  public var beforeCreatedAt: Date?
  public var afterCreatedAt: Date?

  public init(
    before: AlarmSnapshot?, after: AlarmSnapshot?, beforeCreatedAt: Date? = nil,
    afterCreatedAt: Date? = nil
  ) {
    self.before = before
    self.after = after
    self.beforeCreatedAt = beforeCreatedAt
    self.afterCreatedAt = afterCreatedAt
  }
}

public enum AlarmUndo {
  public enum Step: Equatable, Sendable {
    /// Delete the alarm (Undo of an add).
    case remove
    /// Add a new alarm with these settings (Undo of a delete).
    case recreate(AlarmSnapshot)
    /// Put these settings back on the same alarm (Undo of an edit or a switch).
    case restore(AlarmSnapshot)
  }

  /// What Undo does for this change, given the alarm's settings now (nil when it no longer exists).
  /// nil when it can't: the alarm changed since, or is gone, or the row has nothing to put back.
  public static func step(
    for action: LedgerAction, change: AlarmChange, current: AlarmSnapshot?
  ) -> Step? {
    switch action {
    case .deleted:
      return change.before.map(Step.recreate)
    case .created:
      guard let current, current == change.after else { return nil }
      return .remove
    case .edited, .moved, .switchedOn, .switchedOff:
      guard let before = change.before, let current, current == change.after else { return nil }
      return .restore(before)
    default:
      return nil
    }
  }
}

/// What an Activity row says when its Undo could not run.
public enum ActivityUndoMessage {
  /// The item changed again, or is gone.
  public static let changedSince = "Changed since"
}

/// A reminder list's look and place, as Activity keeps it for Undo.
public struct ListSnapshot: Codable, Equatable, Sendable {
  public var name: String
  public var colorIndex: Int
  public var symbol: String
  public var order: Int
  public var pinned: Bool

  public init(
    name: String, colorIndex: Int, symbol: String, order: Int = 0, pinned: Bool = false
  ) {
    self.name = name
    self.colorIndex = colorIndex
    self.symbol = symbol
    self.order = order
    self.pinned = pinned
  }
}

/// One list change: before (nil when added) and after (nil when deleted), and for a delete the reminders that went with it.
/// A delete keeps them only when the list lived in Today alone (never in Apple Reminders), so putting it back is exact.
public struct ListChange: Codable, Equatable {
  public var before: ListSnapshot?
  public var after: ListSnapshot?
  public var tasks: [TaskSnapshot]

  public init(before: ListSnapshot?, after: ListSnapshot?, tasks: [TaskSnapshot] = []) {
    self.before = before
    self.after = after
    self.tasks = tasks
  }
}

public enum ListUndo {
  public enum Step: Equatable {
    /// Delete the list (Undo of an add; it is still empty).
    case remove
    /// Add the list and its reminders back (Undo of a delete).
    case recreate(ListSnapshot, [TaskSnapshot])
    /// Give the list its old name back (its reminders follow).
    case rename(String)
    /// Give the list its old color and symbol back.
    case restyle(colorIndex: Int, symbol: String)
  }

  /// What Undo does, given the list now (nil when it no longer exists), how many reminders it has, and whether another
  /// list already uses the name Undo would bring back. nil when it can't.
  public static func step(
    for action: LedgerAction, change: ListChange, current: ListSnapshot?, taskCount: Int = 0,
    nameTaken: Bool = false
  ) -> Step? {
    switch action {
    case .deleted:
      guard let before = change.before, current == nil, !nameTaken else { return nil }
      return .recreate(before, change.tasks)
    case .created:
      guard let current, let after = change.after, current.name == after.name, taskCount == 0
      else { return nil }
      return .remove
    case .renamed:
      guard let current, let before = change.before, let after = change.after,
        current.name == after.name, !nameTaken
      else { return nil }
      return .rename(before.name)
    case .edited:
      guard let current, let before = change.before, let after = change.after,
        current.colorIndex == after.colorIndex, current.symbol == after.symbol
      else { return nil }
      return .restyle(colorIndex: before.colorIndex, symbol: before.symbol)
    default:
      return nil
    }
  }
}

/// A deleted one-off event, as Activity keeps it so Undo can add it again. `externalID` is the deleted Apple Calendar
/// event's identifier (Undo only runs while it is still gone); a restored event always gets a new one.
public struct EventSnapshot: Codable, Equatable, Sendable {
  public var location: String?
  public var url: String?
  public var busy: Bool?
  public var title: String
  public var start: Date
  public var durationMinutes: Int
  public var isAllDay: Bool
  public var calendarName: String
  public var note: String
  public var externalID: String?
  /// Today kept its own copy (a local event), which comes back too.
  public var local: Bool

  public init(
    title: String, start: Date, durationMinutes: Int, isAllDay: Bool = false,
    calendarName: String = "", note: String = "", externalID: String? = nil, local: Bool = false,
    location: String? = nil, url: String? = nil, busy: Bool? = nil
  ) {
    self.title = title
    self.start = start
    self.durationMinutes = durationMinutes
    self.isAllDay = isAllDay
    self.calendarName = calendarName
    self.note = note
    self.externalID = externalID
    self.local = local
    self.location = location
    self.url = url
    self.busy = busy
  }
}

public enum EventUndo {
  /// What an event row says beside its Undo: a deleted event comes back as a new one, not the same one.
  public static let restoresAsNew = "Restores as a new event"

  /// Whether a deleted event may get Undo from Activity: a one-off with nobody else on it. A series has rules and
  /// exceptions a copy would not carry, and adding back an event with attendees would send them a new invitation.
  /// `attendees` is nil when the Apple Calendar event could not be read (no Undo then); `inAppleCalendar` false means a
  /// Today-only event, which has no attendees.
  public static func canRestore(repeats: Bool, inAppleCalendar: Bool, attendees: Int?) -> Bool {
    guard !repeats else { return false }
    guard inAppleCalendar else { return true }
    return attendees == 0
  }
}

/// When deleting an event may go straight through and when it must ask.
public enum EventDeletePrompt {
  /// Only an event Undo could bring back goes at once. A series needs "this event or the series?", and a cancellation
  /// that has reached attendees cannot be recalled; an Apple event that could not be read is treated the same way.
  public static func asksFirst(repeats: Bool, inAppleCalendar: Bool, attendees: Int?) -> Bool {
    !EventUndo.canRestore(repeats: repeats, inAppleCalendar: inAppleCalendar, attendees: attendees)
  }

  /// A full swipe runs the first swipe button, so it needs Delete to be there. A series never full-swipes. An event with
  /// attendees may, because Delete then opens the question; `audience` is read on the swipe, not for every row.
  public static func allowsFullSwipe(canDelete: Bool, repeats: Bool) -> Bool {
    canDelete && !repeats
  }

  public static func message(title: String, repeats: Bool, attendees: Int?) -> String {
    let lead = repeats ? "“\(title)” repeats." : "Delete “\(title)”? This changes its source."
    guard let attendees, attendees > 0 else { return lead }
    let who = attendees == 1 ? "1 attendee gets" : "\(attendees) attendees get"
    return lead + " \(who) a cancellation, and Undo can’t recall it."
  }
}

private let ciTrialCore = 1

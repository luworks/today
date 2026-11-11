import Foundation
import TodayCore

/// Actual actions on a past day, rebuilt from retained Activity records. Plans are detail context,
/// never evidence of attendance, completion or ringing. Read-only: nothing here writes to Today or Apple.
/// Pure (no SQLite, no SwiftData), so the rules run under `./dev test unit`; `DayHistory.load` pages the store.
public struct DayHistory: Equatable, Sendable {
  /// One immutable action. Identity is the Activity uid, never the current series id.
  public struct Fact: Equatable, Sendable, Identifiable {
    public var event: ActivityEvent
    public var undone: Bool
    public var outcomeUnknown = false
    public var related: [ActivityEvent] = []
    public var id: String { event.uid }
    public var at: Date { event.date }
    public var title: String { event.title ?? "Untitled item" }
    public var action: String {
      if event.kind == ActivityKind.sysAlarmStopped { return "Alarm stopped" }
      switch event.kind {
      case "change.completed":
        if outcomeUnknown { return "Marked complete · Later reopen (occurrence unknown)" }
        return undone ? "Marked complete · No longer complete" : "Marked complete"
      case "change.reopened": return "Reopened"
      case "change.undone": return "Undone"
      default: return event.kind.replacingOccurrences(of: "change.", with: "").capitalized
      }
    }
    public var isPrimary: Bool {
      ["change.completed", "change.reopened", "change.undone", ActivityKind.sysAlarmStopped]
        .contains(event.kind)
    }
  }
  public var facts: [Fact] = []

  public struct Completion: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// When it was marked done (for a completion seen in Apple Reminders, Apple's completion time).
    public var at: Date
    /// The reminder's `subject_ref`, already normalised by the caller's `key`.
    public var ref: String?
  }

  public struct AlarmStop: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var at: Date
    /// The AlarmKit id (`OneAlarm.alarmKitID`), as a UUID string.
    public var alarmID: String?
  }

  public struct DeletedEvent: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var deletedAt: Date
  }

  /// Legacy context summaries. Only `facts` supplies action-history rows and emptiness.
  public var completions: [Completion] = []
  public var alarmStops: [AlarmStop] = []
  public var deletedEvents: [DeletedEvent] = []

  public init(
    completions: [Completion] = [], alarmStops: [AlarmStop] = [],
    deletedEvents: [DeletedEvent] = []
  ) {
    self.completions = completions
    self.alarmStops = alarmStops
    self.deletedEvents = deletedEvents
  }

  public var isEmpty: Bool {
    facts.isEmpty
  }

  public static let observationKind = "change.observed"

  public static let dayKinds = [
    ActivityKind.changePrefix + LedgerAction.completed.rawValue,
    ActivityKind.changePrefix + LedgerAction.reopened.rawValue,
    ActivityKind.sysAlarmStopped,
    "change.created", "change.moved", "change.redated", "change.renamed",
    "change.deleted", "change.unscheduled", "change.planned", "change.updated", "change.undone",
  ]
  public static let deletedKind = ActivityKind.changePrefix + LedgerAction.deleted.rawValue

  /// The rules.
  /// - A completion counts unless it was undone (`undone` holds the uids that have an Undo row) or a later `reopened` of the
  ///   same reminder on the same day took it back.
  /// - `shownLive`: reminders whose live copy is done on this day; the live row shows them, so the ledger row is dropped.
  /// - `reopened`: one-off reminders whose live copy is open again; a completion of theirs was taken back on a later day.
  ///   (A repeating reminder is open again after every completion, so it is never in this set.)
  /// - Legacy deletion intervals remain available as context; elapsed scheduled time never proves attendance.
  /// - `facts` is the action-facing projection. Every action keeps its uid and execution timestamp.
  public static func reconstruct(
    dayEvents: [ActivityEvent], deletions: [ActivityEvent], undone: Set<String>,
    observations: [ActivityEvent] = [], related: [ActivityEvent] = [],
    shownLive: Set<String> = [], reopened: Set<String> = [], key: (String) -> String = { $0 }
  ) -> DayHistory {
    let ordered = dayEvents.sorted { ($0.ts, $0.rowID ?? 0) < ($1.ts, $1.rowID ?? 0) }
    var completions: [Completion] = []
    var open: [String: [Int]] = [:]  // ref -> indices of standing completions, latest last
    var dropped = Set<Int>()
    var stops: [AlarmStop] = []
    let completed = ActivityKind.changePrefix + LedgerAction.completed.rawValue
    let reopenedKind = ActivityKind.changePrefix + LedgerAction.reopened.rawValue
    for e in ordered {
      switch e.kind {
      case completed where (e.subjectKind ?? "task") == "task" && !undone.contains(e.uid):
        let ref = e.subjectRef.map(key)
        completions.append(
          Completion(id: e.uid, title: e.title ?? "", at: e.date, ref: ref))
        if let ref { open[ref, default: []].append(completions.count - 1) }
      case reopenedKind:
        if let ref = e.subjectRef.map(key), let last = open[ref]?.popLast() {
          dropped.insert(last)
        }
      case ActivityKind.sysAlarmStopped:
        stops.append(
          AlarmStop(id: e.uid, title: e.title ?? "", at: e.date, alarmID: e.subjectRef))
      default: break
      }
    }
    let kept = completions.indices.filter { i in
      guard !dropped.contains(i) else { return false }
      guard let ref = completions[i].ref else { return true }
      return !shownLive.contains(ref) && !reopened.contains(ref)
    }.map { completions[$0] }

    let events = deletions.compactMap { e -> DeletedEvent? in
      guard e.kind == deletedKind, e.subjectKind == "event", !undone.contains(e.uid),
        let startMs = e.beforeTs, e.ts >= startMs
      else { return nil }
      let start = ActivityClock.date(ms: startMs)
      let end = e.afterTs.map(ActivityClock.date(ms:)) ?? start
      return DeletedEvent(
        id: e.uid, title: e.title ?? "", start: start, end: max(start, end), deletedAt: e.date)
    }.sorted { $0.start < $1.start }

    var history = DayHistory(completions: kept, alarmStops: stops, deletedEvents: events)
    history.facts = ordered.filter {
      dayKinds.contains($0.kind) && ["task", "alarm", "event"].contains($0.subjectKind ?? "task")
    }
    .map { event in
      let reopenedLater =
        event.kind == "change.completed" && event.beforeTs != nil
        && ordered.contains {
          $0.kind == "change.reopened" && $0.ts >= event.ts
            && event.subjectRef != nil && $0.subjectRef.map(key) == event.subjectRef.map(key)
            && $0.beforeTs == event.beforeTs
        }
      let uncertainReopen =
        event.kind == "change.completed" && event.beforeTs == nil
        && ordered.contains {
          $0.kind == "change.reopened" && $0.ts >= event.ts
            && $0.subjectRef != nil && $0.subjectRef.map(key) == event.subjectRef.map(key)
        }
      return Fact(
        event: event, undone: undone.contains(event.uid) || reopenedLater,
        outcomeUnknown: uncertainReopen)
    }
    // Enrich each action without replacing it with a plan or collapsing other actions in its occurrence.
    var seen = Set<String>()
    let evidence = (dayEvents + related + observations + deletions).filter {
      seen.insert($0.uid).inserted
    }
    let byReference = Dictionary(grouping: evidence) { $0.subjectRef.map(key) ?? "" }
    for index in history.facts.indices {
      let action = history.facts[index].event
      guard let ref = action.subjectRef else { continue }
      let candidates = byReference[key(ref)] ?? []
      var anchors = Set([action.beforeTs, action.afterTs].compactMap { $0 })
      // Explicit move edges alone connect occurrences. Titles and adjacent series dates never do.
      for _ in 0..<min(candidates.count, 200) {
        let before = anchors
        for edit in candidates where ["change.moved", "change.redated"].contains(edit.kind) {
          if let from = edit.beforeTs, let to = edit.afterTs,
            anchors.contains(from) || anchors.contains(to)
          {
            anchors.formUnion([from, to])
          }
        }
        if anchors == before { break }
      }
      var chain = candidates.filter { event in
        event.uid != action.uid
          && (event.beforeTs.map(anchors.contains) == true
            || event.afterTs.map(anchors.contains) == true
            || event.undoOf == action.uid
            || (action.subjectKind == "alarm" && event.kind == deletedKind && event.ts >= action.ts))
      }
      let linkedIDs = Set(chain.map(\.uid) + [action.uid])
      chain += evidence.filter { event in
        event.uid != action.uid && event.undoOf.map(linkedIDs.contains) == true
          && !chain.contains(where: { $0.uid == event.uid })
      }
      history.facts[index].related = chain.sorted { ($0.ts, $0.uid) < ($1.ts, $1.uid) }
      if action.kind == "change.completed" {
        history.facts[index].undone =
          history.facts[index].undone
          || chain.contains {
            $0.ts >= action.ts && ($0.kind == "change.reopened" || $0.undoOf == action.uid)
          }
        history.facts[index].outcomeUnknown =
          history.facts[index].outcomeUnknown
          || (action.beforeTs == nil
            && candidates.contains {
              $0.kind == "change.reopened" && $0.ts >= action.ts
            })
      }
    }
    history.facts.sort { ($0.at, $0.id) < ($1.at, $1.id) }
    return history
  }

  /// Which scheduled rings of the day were stopped. `rings` are (AlarmKit id, ring time); a stop belongs to the latest ring of
  /// the same alarm at or before it, within `window` (snoozes included). Returns the stop time per ring index, and the stops
  /// that matched no ring (an alarm since deleted, or a one-time alarm that has switched itself off): those show on their own.
  public static func matchStops(
    rings: [(alarmID: String?, date: Date)], stops: [AlarmStop], window: TimeInterval = 3 * 3600
  ) -> (stopped: [Int: Date], unmatched: [AlarmStop]) {
    var stopped: [Int: Date] = [:]
    var unmatched: [AlarmStop] = []
    for stop in stops.sorted(by: { $0.at < $1.at }) {
      let candidates = rings.indices.filter { i in
        guard let id = rings[i].alarmID, id == stop.alarmID, stopped[i] == nil else { return false }
        let d = rings[i].date
        return d <= stop.at && stop.at.timeIntervalSince(d) <= window
      }
      if let best = candidates.max(by: { rings[$0].date < rings[$1].date }) {
        stopped[best] = stop.at
      } else {
        unmatched.append(stop)
      }
    }
    return (stopped, unmatched)
  }
}

extension DayHistory {
  /// Reads one day from the store: the day's completions, reopens and alarm stops (`event_kind_day`), the events whose start
  /// falls in the day and that were deleted (`event_kind_before`), and which of those were undone. Paged; `maxRows` bounds a
  /// pathological day.
  public static func load(
    from store: ActivityStore, day: Date, calendar: Calendar, shownLive: Set<String>,
    reopened: Set<String>, key: (String) -> String, maxRows: Int = 2000
  ) throws -> DayHistory {
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    let stamp = ActivityClock.stamp(start, calendar: calendar).day
    func all(_ page: (ActivityCursor?) throws -> [ActivityEvent]) throws -> [ActivityEvent] {
      var out: [ActivityEvent] = []
      var cursor: ActivityCursor?
      while out.count < maxRows {
        let rows = try page(cursor)
        out += rows
        guard rows.count == 200, let next = ActivityCursor(after: rows.last) else { break }
        cursor = next
      }
      return out
    }
    let dayEvents = try all { try store.dayPage(kinds: dayKinds, day: stamp, after: $0) }
    let deletions = try all {
      try store.beforePage(
        kind: deletedKind, startMs: ActivityClock.ms(start), endMs: ActivityClock.ms(end),
        after: $0)
    }
    let observations = try all {
      try store.beforePage(
        kind: observationKind, startMs: ActivityClock.ms(start),
        endMs: ActivityClock.ms(end), after: $0)
    }
    var related: [ActivityEvent] = []
    for ref in Set((dayEvents + observations).compactMap(\.subjectRef)).sorted().prefix(200) {
      related += try store.page(ActivityQuery(subjectRef: ref), limit: 200)
    }
    let undone = try store.undone(among: (dayEvents + deletions + related).map(\.uid))
    return reconstruct(
      dayEvents: dayEvents, deletions: deletions, undone: undone,
      observations: observations, related: related, shownLive: shownLive,
      reopened: reopened, key: key)
  }
}

import Foundation
import TodayCore
import TodayShared

// Builders for the events tiers 2 to 4 record, so the call sites in the screens are one line and the shapes are tested.
// `props` never holds free text (document §2.2); the user's own words go to `content`, and only for an edited card or when the
// user switched chat text on.

public enum ActivityEvents {
  // MARK: Tier 2: AI conversation and decisions

  /// "zh" when the text has CJK characters, else "en".
  public static func language(of text: String) -> String {
    text.unicodeScalars.contains {
      (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
    } ? "zh" : "en"
  }

  /// A message sent in the Ask page. `intent` is where the routing sent it: capture, edit, plan, tidy, review, question, answer.
  /// The text is copied (to `content`, field "input") only when `keepText` is on.
  public static func aiTurn(
    intent: String, route: String, text: String, keepText: Bool, thread: UUID?, at date: Date = .now
  ) -> ActivityEvent {
    var e = ActivityEvent(
      kind: ActivityKind.aiTurn, actor: "you", channel: "ask", at: date,
      props: ActivityProps.json([
        "intent": intent, "route": route, "lang": language(of: text), "len_in": text.count,
      ]))
    e.thread = thread?.uuidString
    if keepText { e.content = [ActivityContent(field: "input", before: nil, after: text)] }
    return e
  }

  /// A preview card appeared. `card`: capture, plan, tidy, change.
  public static func cardShown(
    card: String, items: Int, latencyMs: Int?, thread: UUID?, at date: Date = .now
  ) -> ActivityEvent {
    var props: [String: Any] = ["card": card, "items": items]
    if let latencyMs { props["latency_ms"] = latencyMs }
    var e = ActivityEvent(
      kind: ActivityKind.aiCardShown, actor: "ai", channel: "ask", at: date,
      props: ActivityProps.json(props))
    e.thread = thread?.uuidString
    return e
  }

  /// What the user did with a card: applied, edited (applied after changing it), skipped or cancelled.
  /// Edited fields: only the names in `props`; the before/after words go to `content`.
  public static func cardResolved(
    card: String, outcome: String, edits: [ActivityContent] = [], items: Int = 1,
    dwellMs: Int? = nil,
    thread: UUID?, at date: Date = .now
  ) -> ActivityEvent {
    var props: [String: Any] = ["card": card, "outcome": outcome, "items": items]
    if !edits.isEmpty { props["edited_fields"] = edits.map(\.field) }
    if let dwellMs { props["dwell_ms"] = dwellMs }
    var e = ActivityEvent(
      kind: ActivityKind.aiCardResolved, actor: "you", channel: "ask", at: date,
      props: ActivityProps.json(props))
    e.thread = thread?.uuidString
    e.content = edits
    return e
  }

  /// The user tapped Undo on the Ask page's toast for an AI change.
  public static func aiUndo(card: String, thread: UUID?, at date: Date = .now) -> ActivityEvent {
    var e = ActivityEvent(
      kind: ActivityKind.aiUndo, actor: "you", channel: "ask", at: date,
      props: ActivityProps.json(["card": card]))
    e.thread = thread?.uuidString
    return e
  }

  // MARK: Tier 3: usage

  public static func screenOpen(_ screen: String, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.uiScreenOpen, actor: "you", channel: "app", at: date,
      props: ActivityProps.json(["screen": screen]))
  }

  public static func quickAddCommit(ms: Int, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.uiQuickAddCommit, actor: "you", channel: "app", at: date,
      props: ActivityProps.json(["ms": ms]))
  }

  // MARK: Tier 4: system

  public static func shareImport(count: Int, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.sysShareImport, actor: "system", channel: "share", at: date,
      props: ActivityProps.json(["count": count]))
  }

  public static func intentRun(name: String, outcome: String, at date: Date = .now) -> ActivityEvent
  {
    ActivityEvent(
      kind: ActivityKind.sysIntentRun, actor: "system", channel: "intent", at: date,
      props: ActivityProps.json(["source": name, "outcome": outcome]))
  }

  public static func syncConflict(source: String, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.sysSyncConflict, actor: "system", channel: "sync", at: date,
      props: ActivityProps.json(["source": source]))
  }

  /// The Lock Screen Up Next setting was switched in Settings.
  public static func upNextSetting(on: Bool, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.sysUpNextSetting, actor: "you", channel: "app", at: date,
      props: ActivityProps.json(["on": on]))
  }

  /// The user removed the Up Next card from the Lock Screen.
  public static func upNextDismissed(at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.sysUpNextDismissed, actor: "you", channel: "app", at: date,
      props: ActivityProps.json(["source": "lockscreen"]))
  }

  /// An error with a code, never its message (messages can carry titles).
  public static func error(source: String, code: String, at date: Date = .now) -> ActivityEvent {
    ActivityEvent(
      kind: ActivityKind.sysError, actor: "system", at: date,
      props: ActivityProps.json(["source": source, "error_code": code]))
  }
}

/// What the user changed on an AI capture card before tapping Add: the fields that differ between what the card showed and what
/// was added, with the words before and after (they go to the `content` table, so they can be redacted on their own).
public enum CaptureEdits {
  public static func diff(shown: Capture, final: Capture, calendar: Calendar = .current)
    -> [ActivityContent]
  {
    var out: [ActivityContent] = []
    func add(_ field: String, _ a: String, _ b: String) {
      if a != b { out.append(ActivityContent(field: field, before: a, after: b)) }
    }
    add("title", shown.title, final.title)
    add("when", when(shown, calendar), when(final, calendar))
    add("list", shown.listName ?? "", final.listName ?? "")
    add("kind", kindName(shown), kindName(final))
    add("repeat", shown.repeatRule ?? "", final.repeatRule ?? "")
    add(
      "duration", shown.durationMinutes.map(String.init) ?? "",
      final.durationMinutes.map(String.init) ?? "")
    return out
  }

  private static func kindName(_ c: Capture) -> String {
    c.ringsAsAlarm ? "alarm" : c.kind.rawValue
  }

  /// "2026-10-12 15:00", "2026-10-12", or "" without a day.
  private static func when(_ c: Capture, _ calendar: Calendar) -> String {
    guard c.hasDay || c.hour != nil else { return "" }
    let d = calendar.dateComponents([.year, .month, .day], from: c.day)
    var text = String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    if let h = c.hour { text += String(format: " %02d:%02d", h, c.minute) }
    return text
  }
}

/// Reads the files the Share extension and widgets left in the outbox (`ActivityOutbox`).
public enum ActivityOutboxImport {
  public struct Result {
    public var events: [ActivityEvent] = []
    /// Files fully read (also ones with nothing usable in them); safe to delete once the events are stored.
    public var done: [URL] = []
  }

  public static func read(_ files: [URL]) -> Result {
    var out = Result()
    for file in files {
      guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
      else { continue }
      out.events += ActivityJSONL.events(from: text)
      out.done.append(file)
    }
    return out
  }
}

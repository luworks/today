#if os(iOS) && DEBUG
  import Foundation
  import One
  import SwiftData
  import TodayCore

  /// Evaluation only (docs/qa/agent-p3-eval-20261101.md): lets `TodayIntegrationTests/AgentEvalTests`
  /// drive a hosted `AskView` like a user (send, tap Apply) and read what the chat shows after each turn.
  /// Inert unless a test installs `current` before the view appears.
  @MainActor
  package final class AskEvalProbe {
    package static var current: AskEvalProbe?

    package var send: (String) -> Void = { _ in }
    /// What the chat shows now, as JSON (see `AskView.evalSnapshot`).
    package var snapshot: () -> JSONValue = { .null }
    /// Taps Apply on the open agent change card, as the user would.
    package var applyChange: () async -> Void = {}
    /// Every agent run of this chat, in order (`AskAgentSession.logRun`).
    package var runs: [AgentRunResult] = []

    package init() {}

    /// A stable identity for a stored item, the same one the Ledger and the agent's short ids use.
    package static func key(_ model: some PersistentModel) -> String {
      Ledger.ref(model.persistentModelID).map(Ledger.comparisonKey) ?? ""
    }

    package static func stamp(_ date: Date?, calendar: Calendar, time: Bool = true) -> JSONValue {
      guard let date else { return .null }
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = calendar.timeZone
      f.dateFormat = time ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
      return .string(f.string(from: date))
    }

    package static func capture(_ c: Capture, calendar: Calendar) -> [String: JSONValue] {
      var o: [String: JSONValue] = [
        "kind": .string(c.ringsAsAlarm ? "alarm" : (c.kind == .event ? "event" : "reminder")),
        "title": .string(c.title),
        "day": c.hasDay ? stamp(c.day, calendar: calendar, time: false) : "none",
        "time": c.hour.map { .string(String(format: "%02d:%02d", $0, c.minute)) } ?? "none",
        "repeat": c.repeatRule.map(JSONValue.string) ?? .null,
        "all_day": .bool(c.isAllDay),
        "ready": .bool(c.isReadyToAdd),
      ]
      if let m = c.durationMinutes { o["minutes"] = .number(Double(m)) }
      return o
    }

    package static func tier(_ t: ActionPolicy.Tier) -> JSONValue {
      switch t {
      case .direct: "direct"
      case .preview: "preview"
      case .confirmConsequence: "confirmConsequence"
      case .refuse(let r): .string("refuse:\(r.rawValue)")
      }
    }

    static func agentChange(
      _ change: AskAgentSession.Change, calendar: Calendar
    ) -> JSONValue {
      var o: [String: JSONValue] = [
        "id": .string(change.id), "status": .string(change.status.rawValue),
        "tier": tier(change.card.tier),
        "consequences": .array(change.card.consequences.map(JSONValue.string)),
        "note": change.note.map(JSONValue.string) ?? .null,
      ]
      guard case .change(let c) = change.card.body else { return .object(o) }
      o["title"] = .string(c.title)
      o["before"] = .string(c.before)
      o["after"] = .string(c.after)
      o["attendees"] = .number(Double(c.attendees))
      switch c.target {
      case .task(let t): (o["kind"], o["target"]) = ("reminder", .string(key(t)))
      case .event(let e): (o["kind"], o["target"]) = ("event", .string(key(e)))
      case .alarm(let a): (o["kind"], o["target"]) = ("alarm", .string(key(a)))
      case .system(let s): (o["kind"], o["target"]) = ("event", .string("system:\(s.title)"))
      }
      switch c.operation {
      case .move(let d):
        o["op"] = "move"
        o["new_start"] = stamp(d, calendar: calendar)
      case .rename(let name):
        o["op"] = "rename"
        o["rename"] = .string(name)
      case .done: o["op"] = "done"
      case .delete: o["op"] = "delete"
      }
      return .object(o)
    }
  }
#endif

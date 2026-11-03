import Foundation

/// An event alert as Apple Calendar offers it: a relative offset in seconds from the start (negative = before).
/// Timed events count from their start; all-day events from midnight, so Apple's "On day of event (9:00)" is +9 h.
/// Plain Swift so the tables run under `./dev test unit`; the editor maps a choice to `EKAlarm(relativeOffset:)`.
public enum EventAlert {
  /// Apple's event editors show at most this many alerts in our editor (Apple's own allows more; extra ones are kept).
  public static let maximum = 3

  /// Apple Calendar's choices for a timed event, in its order.
  public static let timed: [TimeInterval] = [
    0, -5 * 60, -10 * 60, -15 * 60, -30 * 60, -3600, -2 * 3600, -86400, -2 * 86400, -7 * 86400,
  ]

  /// Apple Calendar's choices for an all-day event: 9:00 on the day, or 9:00 one or more days before.
  public static let allDay: [TimeInterval] = [
    9 * 3600, 9 * 3600 - 86400, 9 * 3600 - 2 * 86400, 9 * 3600 - 7 * 86400,
  ]

  /// The choices for an event, with `current` added when it is not one of them (an alert set elsewhere is never lost).
  public static func choices(allDay isAllDay: Bool, including current: TimeInterval? = nil)
    -> [TimeInterval]
  {
    let base = isAllDay ? allDay : timed
    guard let current, !base.contains(current) else { return base }
    return base + [current]
  }

  /// "10 minutes before", "At time of event", "1 day before (9:00)".
  public static func label(_ offset: TimeInterval, allDay isAllDay: Bool) -> String {
    let seconds = Int(offset.rounded())
    if isAllDay {
      // Measured from midnight: whole days before plus a time of day.
      let dayStart = Int((Double(seconds) / 86400).rounded(.down))
      let timeOfDay = seconds - dayStart * 86400
      let clock = String(format: "%d:%02d", timeOfDay / 3600, (timeOfDay % 3600) / 60)
      switch dayStart {
      case 0: return "On day of event (\(clock))"
      case ..<0: return "\(plural(-dayStart, "day")) before (\(clock))"
      default: return "\(plural(dayStart, "day")) after (\(clock))"
      }
    }
    if seconds == 0 { return "At time of event" }
    let before = seconds < 0
    let magnitude = abs(seconds)
    let amount: String
    if magnitude % 604_800 == 0 {
      amount = plural(magnitude / 604_800, "week")
    } else if magnitude % 86400 == 0 {
      amount = plural(magnitude / 86400, "day")
    } else if magnitude % 3600 == 0 {
      amount = plural(magnitude / 3600, "hour")
    } else {
      amount = plural(max(1, magnitude / 60), "minute")
    }
    return amount + (before ? " before" : " after")
  }

  private static func plural(_ n: Int, _ unit: String) -> String {
    "\(n) \(unit)\(n == 1 ? "" : "s")"
  }
}

/// Where a new event goes: an explicit calendar first, then Settings → "New events go to", then the system default.
/// Only calendars that exist and can be written count; otherwise the next rule decides.
public enum EventCalendarChoice {
  public struct Candidate: Equatable, Sendable {
    public let id: String
    public let title: String
    public let writable: Bool
    public init(id: String, title: String, writable: Bool = true) {
      self.id = id
      self.title = title
      self.writable = writable
    }
  }

  /// The calendar id to write to; nil = the system default calendar.
  public static func resolve(
    explicit: String?, preferred: String?, calendars: [Candidate]
  ) -> String? {
    let usable = Set(calendars.filter(\.writable).map(\.id))
    if let explicit, usable.contains(explicit) { return explicit }
    if let preferred, usable.contains(preferred) { return preferred }
    return nil
  }

  /// The writable calendar the user's own words name ("dinner with the family" → "Family"), else nil.
  /// Conservative like `ListGuess`: a whole calendar name in the text, and exactly one calendar matching.
  public static func named(in text: String, calendars: [Candidate]) -> String? {
    let lowered = text.lowercased()
    let hits = calendars.filter { c in
      guard c.writable else { return false }
      let name = c.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard name.count >= 2, let range = lowered.range(of: name) else { return false }
      // Latin names must be whole words ("Work" is not in "homework"); CJK names have no spaces to check.
      guard name.unicodeScalars.allSatisfy({ $0.isASCII }) else { return true }
      let before =
        range.lowerBound == lowered.startIndex
        ? nil : lowered[lowered.index(before: range.lowerBound)]
      let after = range.upperBound == lowered.endIndex ? nil : lowered[range.upperBound]
      return !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
    }
    let ids = Set(hits.map(\.id))
    return ids.count == 1 ? ids.first : nil
  }

  /// The calendar the model named, matched to a writable calendar by title (case-insensitive), else nil.
  public static func matching(title raw: String?, calendars: [Candidate]) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty
    else { return nil }
    let hits = calendars.filter { $0.writable && $0.title.lowercased() == raw }
    return hits.count == 1 ? hits.first?.id : nil
  }
}

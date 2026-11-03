import Foundation

/// An event alert's words, as Apple Calendar says them: `offset` seconds from the start (negative = before).
public enum EventAlert {
  /// "10 minutes before", "At time of event", "1 hour before".
  public static func label(_ offset: TimeInterval) -> String {
    let seconds = Int(offset.rounded())
    if seconds == 0 { return "At time of event" }
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
    return amount + (seconds < 0 ? " before" : " after")
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
}

import Foundation

public enum ButlerGreeting {
  public struct Item: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var isAllDay: Bool

    public init(title: String, start: Date, isAllDay: Bool = false) {
      self.title = title
      self.start = start
      self.isAllDay = isAllDay
    }
  }

  public struct Day: Equatable, Sendable {
    public var today: [Item]
    public var anytime: Int
    public var overdue: Int
    public var tomorrow: [Item]
    public var isComplete: Bool

    public init(
      today: [Item] = [], anytime: Int = 0, overdue: Int = 0, tomorrow: [Item] = [],
      isComplete: Bool = true
    ) {
      self.today = today
      self.anytime = anytime
      self.overdue = overdue
      self.tomorrow = tomorrow
      self.isComplete = isComplete
    }
  }

  public static let maxLength = 90

  public static func salutation(at now: Date, calendar: Calendar) -> String {
    switch calendar.component(.hour, from: now) {
    case 5..<12: "Good morning."
    case 12..<17: "Good afternoon."
    default: "Good evening."
    }
  }

  public static func text(_ day: Day, now: Date, calendar: Calendar, locale: Locale) -> String {
    let hello = salutation(at: now, calendar: calendar)
    guard day.isComplete else { return hello }
    let time = { (date: Date) in
      date.formatted(
        Date.FormatStyle(
          date: .omitted, time: .shortened, locale: locale, calendar: calendar,
          timeZone: calendar.timeZone))
    }
    let left = day.today.filter { calendar.isDate($0.start, inSameDayAs: now) }
    let remaining = left.count + day.anytime
    let overdue = day.overdue
    if let next = left.first(where: { !$0.isAllDay && $0.start > now }) {
      let tail =
        remaining > 1
        ? "; \(words(remaining)) things remain today"
          + (overdue > 0 ? ", \(words(overdue)) overdue." : ".")
        : ", the last today" + (overdue > 0 ? "; \(words(overdue)) overdue." : ".")
      return fit(hello + " Next is ", next.title, " at \(time(next.start))" + tail)
    }
    if remaining > 0 {
      let lead =
        remaining == 1
        ? "One thing remains today, at no set time"
        : "\(capitalized(words(remaining))) things remain today, none at a set time"
      return "\(hello) \(lead)" + (overdue > 0 ? "; \(words(overdue)) overdue." : ".")
    }
    let evening = hello == "Good evening."
    let rest =
      evening
      ? "Nothing further today" + (overdue > 0 ? "; \(words(overdue)) overdue." : ".")
      : "Your day is clear"
        + (overdue > 0 ? ", save \(count(overdue, "overdue item", "overdue items"))." : ".")
    let opening = "\(hello) \(rest)"
    guard let first = firstOf(day.tomorrow) else { return opening }
    if first.isAllDay {
      return fit(opening + " Tomorrow begins with ", first.title, ".")
    }
    return fit(opening + " Tomorrow begins at \(time(first.start)) with ", first.title, ".")
  }

  static func firstOf(_ items: [Item]) -> Item? {
    items.filter { !$0.isAllDay }.min { $0.start < $1.start } ?? items.first
  }

  static func fit(_ head: String, _ title: String, _ tail: String) -> String {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = clean.isEmpty ? "Untitled" : clean
    let budget = max(maxLength - head.count - tail.count, 12)
    guard shown.count > budget else { return head + shown + tail }
    let cut = shown.prefix(budget - 1).trimmingCharacters(in: .whitespaces)
    return head + cut + "…" + tail
  }

  static let names = [
    "no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
    "twelve",
  ]

  public static func words(_ n: Int) -> String {
    names.indices.contains(n) ? names[n] : String(n)
  }

  static func count(_ n: Int, _ one: String, _ many: String) -> String {
    "\(words(n)) \(n == 1 ? one : many)"
  }

  static func capitalized(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
  }
}

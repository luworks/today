import Foundation

/// A user-made exception to one local event occurrence. The series anchor remains unchanged.
public struct OccurrenceTimeOverride: Codable, Equatable, Sendable {
  public let original: Date
  public let start: Date
  public init(original: Date, start: Date) {
    self.original = original
    self.start = start
  }
}

public enum OccurrenceTimes {
  public static func starts(
    start: Date, duration: TimeInterval, rule: RepeatRule?,
    overrides: [OccurrenceTimeOverride], in interval: DateInterval,
    calendar: Calendar = .current
  ) -> [Date] {
    guard rule != nil, !overrides.isEmpty else {
      return Recurrence.occurrences(
        start: start, duration: duration, rule: rule, in: interval, calendar: calendar)
    }
    // Same-day exceptions may move into a narrow query from earlier or later in that day.
    let first = calendar.startOfDay(for: interval.start)
    let last =
      calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: interval.end))
      ?? interval.end
    let base = Recurrence.occurrences(
      start: start, duration: duration, rule: rule,
      in: DateInterval(start: first, end: last), calendar: calendar)
    return base.map { original in
      overrides.first(where: { $0.original == original })?.start ?? original
    }
    .filter { $0 < interval.end && $0.addingTimeInterval(max(1, duration)) > interval.start }
    .sorted()
  }

  public static func moving(
    _ overrides: [OccurrenceTimeOverride], from current: Date, to target: Date
  )
    -> [OccurrenceTimeOverride]
  {
    let original = overrides.first(where: { $0.start == current })?.original ?? current
    let retained = overrides.filter { $0.original != original }
    return target == original ? retained : retained + [.init(original: original, start: target)]
  }
}

import Foundation

/// The range one timeline item may start in on its day. Where it lands comes from `TimelineDropPlan`.
public struct TimelineDragTime: Equatable, Sendable {
  public let original: Date
  public let earliest: Date
  public let latest: Date
  public let duration: TimeInterval

  public init?(
    original: Date, day: Date, duration: TimeInterval = 0,
    calendar: Calendar, minimumStart: Date? = nil, maximumStart: Date? = nil
  ) {
    guard duration >= 0, duration.isFinite,
      let interval = calendar.dateInterval(of: .day, for: day),
      interval.contains(original), duration <= interval.duration
    else { return nil }
    let lower = max(interval.start, minimumStart ?? interval.start)
    let upper = min(
      interval.end.addingTimeInterval(-max(duration, 60)), maximumStart ?? interval.end)
    guard lower.timeIntervalSinceReferenceDate.isFinite,
      upper.timeIntervalSinceReferenceDate.isFinite, lower <= upper
    else { return nil }
    self.original = original
    earliest = lower
    latest = upper
    self.duration = duration
  }
}

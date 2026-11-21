import Foundation

public struct TimelineDropAnchor: Equatable, Sendable {
  public let start: Date
  public let end: Date

  public init(start: Date, end: Date? = nil) {
    self.start = start
    self.end = end ?? start
  }
}

public struct TimelineDropStop: Equatable, Sendable {
  public let index: Int
  public let target: Date
}

public enum TimelineDropPlan {
  private static let minute: TimeInterval = 60
  private static let grid: TimeInterval = 300
  private static let edgeDistance: TimeInterval = 1800

  public static func stops(
    anchors unrounded: [TimelineDropAnchor], originalIndex: Int, timing: TimelineDragTime,
    day: Date, calendar: Calendar
  ) -> [TimelineDropStop] {
    guard let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
    let anchors = unrounded.map {
      TimelineDropAnchor(start: wholeMinute($0.start), end: wholeMinute($0.end))
    }
    return (0...anchors.count).compactMap { index in
      if index == originalIndex {
        return TimelineDropStop(index: index, target: timing.original)
      }
      return target(index: index, anchors: anchors, timing: timing, bounds: bounds).map {
        TimelineDropStop(index: index, target: $0)
      }
    }
  }

  private static func target(
    index: Int, anchors: [TimelineDropAnchor], timing: TimelineDragTime, bounds: DateInterval
  ) -> Date? {
    let previous = index > 0 ? anchors[index - 1] : nil
    let next = index < anchors.count ? anchors[index] : nil
    let previousEnd = previous.map { prior in
      next.map { prior.end > $0.start } == true ? prior.start : prior.end
    }
    let lower = max(bounds.start, previousEnd ?? bounds.start)
    let upper = min(bounds.end, next?.start ?? bounds.end)
    let proposed =
      edgeTime(
        previous: previous, next: next, lower: lower, upper: upper, timing: timing,
        day: bounds.start)
      ?? gapTime(lower: lower, upper: upper, timing: timing, origin: bounds.start)
    return allowed(proposed, lower: lower, upper: upper, timing: timing, bounds: bounds)
  }

  private static func edgeTime(
    previous: TimelineDropAnchor?, next: TimelineDropAnchor?, lower: Date, upper: Date,
    timing: TimelineDragTime, day: Date
  ) -> Date? {
    let proposed: Date
    switch (previous, next) {
    case (nil, let next?):
      proposed = rounded(
        next.start.addingTimeInterval(-edgeDistance - timing.duration), origin: day)
    case (let previous?, nil):
      proposed = rounded(previous.end.addingTimeInterval(edgeDistance), origin: day)
    default: return nil
    }
    guard proposed >= lower, proposed.addingTimeInterval(timing.duration) <= upper,
      timing.duration > 0 || proposed < upper
    else { return nil }
    return proposed
  }

  private static func gapTime(
    lower: Date, upper: Date, timing: TimelineDragTime, origin: Date
  ) -> Date {
    let gap = upper.timeIntervalSince(lower)
    if timing.duration > 0 {
      guard gap > timing.duration else { return lower }
      let start = rounded(lower.addingTimeInterval((gap - timing.duration) / 2), origin: origin)
      return start >= lower && start.addingTimeInterval(timing.duration) <= upper ? start : lower
    }
    guard gap > 0 else { return lower }
    let afterPrevious = lower.addingTimeInterval(minute)
    guard gap >= grid else { return afterPrevious }
    let middle = rounded(lower.addingTimeInterval(gap / 2), origin: origin)
    return middle > lower && middle < upper ? middle : afterPrevious
  }

  private static func allowed(
    _ proposed: Date, lower: Date, upper: Date, timing: TimelineDragTime, bounds: DateInterval
  ) -> Date? {
    var result = proposed
    if result < timing.earliest {
      guard timing.earliest <= upper else { return nil }
      result = timing.earliest
    }
    if result > timing.latest {
      guard timing.latest >= lower else { return nil }
      result = timing.latest
    }
    return result >= bounds.start && result < bounds.end ? result : nil
  }

  private static func rounded(_ date: Date, origin: Date) -> Date {
    origin.addingTimeInterval((date.timeIntervalSince(origin) / grid).rounded() * grid)
  }

  private static func wholeMinute(_ date: Date) -> Date {
    Date(
      timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / minute) * minute)
  }
}

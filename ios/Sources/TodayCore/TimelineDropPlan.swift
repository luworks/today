import Foundation

/// Something a dragged row lands between: an item of the day, or the Now line.
public struct TimelineDropAnchor: Equatable, Sendable {
  public let start: Date
  public let end: Date

  public init(start: Date, end: Date? = nil) {
    self.start = start
    self.end = end ?? start
  }
}

/// One place a row can be dropped, and the time it would get there.
public struct TimelineDropStop: Equatable, Sendable {
  public let part: DayPart
  /// How many anchors sit above this place.
  public let index: Int
  public let target: Date
}

/// Works out a dropped row's time from the items around the place it lands.
public enum TimelineDropPlan {
  private static let minute: TimeInterval = 60
  private static let grid: TimeInterval = 300
  private static let edgeDistance: TimeInterval = 1800

  /// Every usable place, top to bottom. Each card offers its top and its bottom, so the anchors at a
  /// boundary give two places; a part with no anchors offers one. `anchors` run in timeline order,
  /// without the dragged row; `originalIndex` is how many of them sit above it. Its own place always
  /// answers its original time, so releasing there changes nothing.
  public static func stops(
    anchors unrounded: [TimelineDropAnchor], originalIndex: Int, timing: TimelineDragTime,
    day: Date, calendar: Calendar, boundaries: DayPart.Boundaries = .standard
  ) -> [TimelineDropStop] {
    let anchors = unrounded.map {
      TimelineDropAnchor(start: wholeMinute($0.start), end: wholeMinute($0.end))
    }
    let originalPart = DayPart.of(
      timing.original, day: day, calendar: calendar, boundaries: boundaries)
    var stops: [TimelineDropStop] = []
    var firstOfPart = 0
    for part in DayPart.allCases {
      let held = anchors[firstOfPart...].prefix {
        DayPart.of($0.start, day: day, calendar: calendar, boundaries: boundaries) == part
      }.count
      for index in firstOfPart...(firstOfPart + held) {
        if part == originalPart, index == originalIndex {
          stops.append(TimelineDropStop(part: part, index: index, target: timing.original))
        } else if let target = target(
          part: part, index: index, partIsEmpty: held == 0, anchors: anchors, timing: timing,
          day: day, calendar: calendar, boundaries: boundaries)
        {
          stops.append(TimelineDropStop(part: part, index: index, target: target))
        }
      }
      firstOfPart += held
    }
    return stops
  }

  private static func target(
    part: DayPart, index: Int, partIsEmpty: Bool, anchors: [TimelineDropAnchor],
    timing: TimelineDragTime, day: Date, calendar: Calendar, boundaries: DayPart.Boundaries
  ) -> Date? {
    guard let bounds = part.bounds(day: day, calendar: calendar, boundaries: boundaries) else {
      return nil
    }
    let previous = index > 0 ? anchors[index - 1] : nil
    let next = index < anchors.count ? anchors[index] : nil
    // An event that runs past the next item cannot be stayed clear of; the order can still hold.
    let previousEnd = previous.map { prior in
      next.map { prior.end > $0.start } == true ? prior.start : prior.end
    }
    let lower = max(bounds.start, previousEnd ?? bounds.start)
    let upper = min(bounds.end, next?.start ?? bounds.end)

    let proposed: Date
    if partIsEmpty {
      guard let usual = part.usualTime(day: day, calendar: calendar, boundaries: boundaries) else {
        return nil
      }
      proposed = max(usual, lower)
    } else if let edge = edgeTime(
      previous: previous, next: next, lower: lower, upper: upper, timing: timing, day: bounds.start)
    {
      proposed = edge
    } else {
      proposed = gapTime(lower: lower, upper: upper, timing: timing, origin: bounds.start)
    }
    return allowed(
      proposed, lower: lower, upper: upper, part: part, timing: timing, day: day,
      calendar: calendar,
      boundaries: boundaries)
  }

  /// First or last in the day: half an hour from the neighbour, if that stays in this slot.
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
      // An event that does not fit starts where the previous item ends and shows the overlap warning.
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

  /// Applies the item's own limits; nil when the place cannot hold it (a one-off alarm above Now).
  private static func allowed(
    _ proposed: Date, lower: Date, upper: Date, part: DayPart, timing: TimelineDragTime, day: Date,
    calendar: Calendar, boundaries: DayPart.Boundaries
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
    return DayPart.of(result, day: day, calendar: calendar, boundaries: boundaries) == part
      ? result : nil
  }

  private static func rounded(_ date: Date, origin: Date) -> Date {
    origin.addingTimeInterval((date.timeIntervalSince(origin) / grid).rounded() * grid)
  }

  private static func wholeMinute(_ date: Date) -> Date {
    Date(
      timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / minute) * minute)
  }
}

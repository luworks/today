import Foundation

/// A drag uses elapsed minutes at a frozen scale, never compressed agenda row distances.
public struct TimelineDragTime: Equatable, Sendable {
  public let original: Date
  public let earliest: Date
  public let latest: Date
  public let pointsPerMinute: Double

  public init?(
    original: Date, day: Date, duration: TimeInterval = 0,
    calendar: Calendar, pointsPerMinute: Double = 2
  ) {
    guard duration >= 0, duration.isFinite, pointsPerMinute > 0,
      pointsPerMinute.isFinite,
      let interval = calendar.dateInterval(of: .day, for: day),
      interval.contains(original), duration <= interval.duration
    else { return nil }
    self.original = original
    earliest = interval.start
    latest = interval.end.addingTimeInterval(-max(duration, 60))
    self.pointsPerMinute = pointsPerMinute
  }

  public func target(translation: Double) -> Date {
    guard translation.isFinite else { return original }
    // Zero displacement preserves an existing off-grid minute exactly.
    guard abs(translation) >= pointsPerMinute * 2.5 else { return original }
    let proposed = original.addingTimeInterval(translation / pointsPerMinute * 60)
    let minutes = proposed.timeIntervalSince(earliest) / 300
    let snapped = earliest.addingTimeInterval(minutes.rounded() * 300)
    return min(latest, max(earliest, snapped))
  }
}

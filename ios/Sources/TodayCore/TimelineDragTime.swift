import Foundation

/// A drag uses elapsed minutes at a frozen scale, never compressed agenda row distances.
public struct TimelineDragTime: Equatable, Sendable {
  public let original: Date
  public let earliest: Date
  public let latest: Date
  public let pointsPerMinute: Double
  public let duration: TimeInterval
  private let gridOrigin: Date

  public init?(
    original: Date, day: Date, duration: TimeInterval = 0,
    calendar: Calendar, pointsPerMinute: Double = 2, minimumStart: Date? = nil
  ) {
    guard duration >= 0, duration.isFinite, pointsPerMinute > 0,
      pointsPerMinute.isFinite,
      let interval = calendar.dateInterval(of: .day, for: day),
      interval.contains(original), duration <= interval.duration
    else { return nil }
    let lower = max(interval.start, minimumStart ?? interval.start)
    let upper = interval.end.addingTimeInterval(-max(duration, 60))
    guard lower.timeIntervalSinceReferenceDate.isFinite, lower <= upper else { return nil }
    self.original = original
    gridOrigin = interval.start
    earliest = lower
    latest = upper
    self.duration = duration
    self.pointsPerMinute = pointsPerMinute
  }

  public func target(translation: Double) -> Date {
    guard translation.isFinite else { return original }
    // Zero displacement preserves an existing off-grid minute exactly.
    guard abs(translation) >= pointsPerMinute * 2.5 else { return original }
    let proposed = original.addingTimeInterval(translation / pointsPerMinute * 60)
    let minutes = proposed.timeIntervalSince(gridOrigin) / 300
    let snapped = gridOrigin.addingTimeInterval(minutes.rounded() * 300)
    return min(latest, max(earliest, snapped))
  }
}

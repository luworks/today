/// A shared, fixed 00:00–24:00 clock axis for the visible calendar days.
/// Inputs are wall-clock minutes (as in CalendarDayAxis), not elapsed DST minutes.
public struct CalendarGapLayout: Sendable {
  /// A half-open interval. Intervals used as occupied time are clipped to the day;
  /// empty, reversed and non-finite intervals are ignored.
  public struct Interval: Hashable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
      self.start = start
      self.end = end
    }
  }

  public struct Day: Sendable {
    public let intervals: [Interval]
    public let marks: [Double]

    public init(intervals: [Interval] = [], marks: [Double] = []) {
      self.intervals = intervals
      self.marks = marks
    }
  }

  /// Maximal common free runs of whole clock hours, filtered by minimum duration.
  /// These identities remain the same when a gap is expanded.
  public let gaps: [Interval]
  public let height: Double
  private let pointsPerMinute: Double
  private let compressedGapHeight: Double
  private let expandedGaps: Set<Interval>

  /// Heights and the minimum duration must be finite and positive. A positive compressed
  /// height keeps the mapping strictly increasing and therefore invertible.
  public init(
    days: [Day], pointsPerHour: Double, minimumGapMinutes: Double,
    compressedGapHeight: Double, expandedGaps: Set<Interval> = []
  ) {
    precondition(pointsPerHour.isFinite && pointsPerHour > 0)
    precondition(minimumGapMinutes.isFinite && minimumGapMinutes > 0)
    precondition(compressedGapHeight.isFinite && compressedGapHeight > 0)

    var barriers: [Interval] = []
    for day in days {
      for interval in day.intervals
      where interval.start.isFinite && interval.end.isFinite && interval.start < interval.end {
        let start = max(0, (interval.start / 60).rounded(.down) * 60)
        let end = min(1440, (interval.end / 60).rounded(.up) * 60)
        if start < end {
          barriers.append(Interval(start: start, end: end))
        }
      }
      // Midnight at 1440 belongs to the next day, not the final hour of this one.
      for mark in day.marks where mark.isFinite && mark >= 0 && mark < 1440 {
        let start = (mark / 60).rounded(.down) * 60
        barriers.append(Interval(start: start, end: start + 60))
      }
    }
    barriers.sort { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
    var found: [Interval] = []
    var cursor = 0.0
    if !days.isEmpty {
      for barrier in barriers {
        if barrier.start - cursor >= minimumGapMinutes {
          found.append(Interval(start: cursor, end: barrier.start))
        }
        cursor = max(cursor, barrier.end)
      }
      if 1440 - cursor >= minimumGapMinutes {
        found.append(Interval(start: cursor, end: 1440))
      }
    }
    self.gaps = found
    self.pointsPerMinute = pointsPerHour / 60
    self.compressedGapHeight = compressedGapHeight
    self.expandedGaps = expandedGaps
    let savedHeight = found.reduce(0.0) { total, gap in
      let full = (gap.end - gap.start) * (pointsPerHour / 60)
      return total + (expandedGaps.contains(gap) ? 0 : max(0, full - compressedGapHeight))
    }
    self.height = 1440 * (pointsPerHour / 60) - savedHeight
  }

  private func gapScale(_ gap: Interval) -> Double {
    if expandedGaps.contains(gap) { return pointsPerMinute }
    return min(pointsPerMinute, compressedGapHeight / (gap.end - gap.start))
  }

  /// The coordinate of a wall-clock minute, including for the current-time indicator.
  /// Finite values outside the day are clamped.
  public func y(forMinute minute: Double) -> Double {
    precondition(minute.isFinite)
    let minute = min(1440, max(0, minute))
    var y = minute * pointsPerMinute
    for gap in gaps where minute > gap.start {
      let length = min(minute, gap.end) - gap.start
      y -= length * (pointsPerMinute - gapScale(gap))
    }
    return y
  }

  /// Inverse of y(forMinute:); finite positions outside the layout are clamped.
  public func minute(atY y: Double) -> Double {
    precondition(y.isFinite)
    let y = min(height, max(0, y))
    var minute = 0.0
    var position = 0.0
    for gap in gaps {
      let leadingHeight = (gap.start - minute) * pointsPerMinute
      if y <= position + leadingHeight {
        return minute + (y - position) / pointsPerMinute
      }
      position += leadingHeight
      let scale = gapScale(gap)
      let gapHeight = (gap.end - gap.start) * scale
      if y <= position + gapHeight {
        return gap.start + (y - position) / scale
      }
      position += gapHeight
      minute = gap.end
    }
    return min(1440, minute + (y - position) / pointsPerMinute)
  }

  /// Visual height of a duration, including any crossed compressed gaps.
  /// Reversed endpoints produce zero; each endpoint is clamped independently.
  public func height(from start: Double, to end: Double) -> Double {
    max(0, y(forMinute: end) - y(forMinute: start))
  }
}

/// Presentation values shared by the calendar gap label and its placement.
public enum CalendarGapPresentation {
  public static func rangeLabel(start: Double, end: Double) -> String {
    func hour(_ minute: Double) -> String {
      let value = Int(minute / 60)
      return value < 10 ? "0\(value)" : "\(value)"
    }
    return "\(hour(start))–\(hour(end))"
  }

  public static func centerY(axis: CalendarGapLayout, gap: CalendarGapLayout.Interval) -> Double {
    (axis.y(forMinute: gap.start) + axis.y(forMinute: gap.end)) / 2
  }
}

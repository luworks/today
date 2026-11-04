import Foundation

/// The fixed 00–24 clock axis used by Calendar 2 Day, independent of elapsed DST hours.
/// Repeated local times share a coordinate; missing spring hours remain on the axis.
public enum CalendarDayAxis {
  /// Current-time markers belong only to the actual local day.
  public static func currentMinute(on day: Date, now: Date, calendar: Calendar) -> Double? {
    calendar.isDate(day, inSameDayAs: now) ? minute(now, calendar: calendar) : nil
  }

  public static func minute(_ date: Date, calendar: Calendar) -> Double {
    let c = calendar.dateComponents([.hour, .minute, .second], from: date)
    return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
  }

  /// Clip using absolute dates, then project onto the local clock. A rollback can reverse
  /// clock endpoints, so retain the existing 30-minute minimum visual block in that case.
  /// This is presentation geometry only and never changes the event's dates.
  public static func span(
    start: Date, end: Date, in day: DateInterval, calendar: Calendar
  ) -> (start: Double, end: Double) {
    let s = max(start, day.start)
    let t = min(max(end, start.addingTimeInterval(1800)), day.end)
    let first = s <= day.start ? 0 : minute(s, calendar: calendar)
    let last = t >= day.end ? 1440 : minute(t, calendar: calendar)
    return (first, min(1440, max(last, first + min(30, t.timeIntervalSince(s) / 60))))
  }
}

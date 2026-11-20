import Foundation

public enum MonthWeekStrip {
  public static func weekStart(of day: Date, calendar: Calendar) -> Date {
    let start = calendar.startOfDay(for: day)
    let weekday = calendar.component(.weekday, from: start)
    let back = (weekday - calendar.firstWeekday + 7) % 7
    return calendar.date(byAdding: .day, value: -back, to: start) ?? start
  }

  public static func days(ofWeek day: Date, calendar: Calendar) -> [Date] {
    let first = weekStart(of: day, calendar: calendar)
    return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
  }

  public static func weekOffset(of day: Date, from reference: Date, calendar: Calendar) -> Int {
    let a = weekStart(of: reference, calendar: calendar)
    let b = weekStart(of: day, calendar: calendar)
    let days = calendar.dateComponents([.day], from: a, to: b).day ?? 0
    return Int((Double(days) / 7).rounded(.down))
  }

  public static func week(_ offset: Int, from reference: Date, calendar: Calendar) -> Date {
    let a = weekStart(of: reference, calendar: calendar)
    return calendar.date(byAdding: .day, value: offset * 7, to: a) ?? a
  }

  public static func shifted(_ day: Date, weeks: Int, calendar: Calendar) -> Date {
    let d = calendar.startOfDay(for: day)
    return calendar.date(byAdding: .day, value: weeks * 7, to: d) ?? d
  }

  public static func row(of day: Date, inMonthWeeks weeks: [[Date?]], calendar: Calendar) -> Int {
    weeks.firstIndex { week in
      week.contains { $0.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
    } ?? 0
  }

  public static func progress(collapsed: Bool, translation: Double, distance: Double) -> Double {
    guard distance > 0 else { return collapsed ? 1 : 0 }
    let start = collapsed ? 1.0 : 0.0
    return min(1, max(0, start - translation / distance))
  }

  public static func settlesCollapsed(
    progress: Double, predictedTranslation: Double, distance: Double
  )
    -> Bool
  {
    let fling = distance > 0 ? predictedTranslation / distance : 0
    if fling <= -0.5 { return true }
    if fling >= 0.5 { return false }
    return progress >= 0.5
  }
}

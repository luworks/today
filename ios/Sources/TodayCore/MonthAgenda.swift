import Foundation

public struct MonthAgendaItem: Sendable {
  public let start: Date
  public let end: Date
  public let isAllDay: Bool
  public let title: String

  public init(start: Date, end: Date, isAllDay: Bool, title: String) {
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.title = title
  }
}

public struct MonthAgendaRowFrame: Sendable, Equatable {
  public let day: Date
  public let minY: Double
  public let maxY: Double

  public init(day: Date, minY: Double, maxY: Double) {
    self.day = day
    self.minY = minY
    self.maxY = maxY
  }
}

public enum MonthAgenda {
  public enum Relative: Sendable, Equatable { case yesterday, today, tomorrow }

  public static func days(around day: Date, before: Int, after: Int, calendar: Calendar)
    -> [Date]
  {
    let anchor = calendar.startOfDay(for: day)
    let first = calendar.date(byAdding: .day, value: -before, to: anchor) ?? anchor
    return days(from: first, count: before + after + 1, calendar: calendar)
  }

  public static func days(from start: Date, count: Int, calendar: Calendar) -> [Date] {
    let first = calendar.startOfDay(for: start)
    return (0..<max(0, count)).compactMap {
      calendar.date(byAdding: .day, value: $0, to: first)
    }
  }

  public static func prepending(_ count: Int, to days: [Date], calendar: Calendar) -> [Date] {
    guard let first = days.first,
      let start = calendar.date(byAdding: .day, value: -count, to: first)
    else { return days }
    return Self.days(from: start, count: count, calendar: calendar) + days
  }

  public static func appending(_ count: Int, to days: [Date], calendar: Calendar) -> [Date] {
    guard let last = days.last, let start = calendar.date(byAdding: .day, value: 1, to: last)
    else { return days }
    return days + Self.days(from: start, count: count, calendar: calendar)
  }

  public static func contains(_ day: Date, in days: [Date], calendar: Calendar) -> Bool {
    guard let first = days.first, let last = days.last else { return false }
    let d = calendar.startOfDay(for: day)
    return d >= first && d <= last
  }

  public static func sections(days: [Date], items: [MonthAgendaItem], calendar: Calendar)
    -> [[Int]]
  {
    var buckets = Array(repeating: [Int](), count: days.count)
    guard let first = days.first, let last = days.last else { return buckets }
    var index: [Date: Int] = [:]
    for (i, d) in days.enumerated() { index[d] = i }
    for (i, item) in items.enumerated() {
      if item.start == item.end {
        if let slot = index[calendar.startOfDay(for: item.start)] { buckets[slot].append(i) }
        continue
      }
      var d = max(calendar.startOfDay(for: item.start), first)
      while d < item.end, d <= last {
        if let slot = index[d] { buckets[slot].append(i) }
        guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
        d = next
      }
    }
    for (slot, day) in days.enumerated() {
      guard let interval = calendar.dateInterval(of: .day, for: day) else { continue }
      func key(_ item: MonthAgendaItem) -> (Bool, Date) {
        if item.isAllDay { return (true, interval.start) }
        let allDay = item.start <= interval.start && item.end >= interval.end
        return (allDay, max(item.start, interval.start))
      }
      buckets[slot].sort { l, r in
        let a = key(items[l])
        let b = key(items[r])
        if a.0 != b.0 { return a.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if items[l].title != items[r].title { return items[l].title < items[r].title }
        return l < r
      }
    }
    return buckets
  }

  public static func topDay(rows: [MonthAgendaRowFrame], top: Double) -> Date? {
    let straddling = rows.filter { $0.minY <= top && $0.maxY > top }
    if let row = straddling.max(by: { $0.minY < $1.minY }) { return row.day }
    return rows.filter { $0.minY > top }.min(by: { $0.minY < $1.minY })?.day
  }

  public static func relative(_ day: Date, today: Date, calendar: Calendar) -> Relative? {
    let d = calendar.startOfDay(for: day)
    let t = calendar.startOfDay(for: today)
    guard let delta = calendar.dateComponents([.day], from: t, to: d).day else { return nil }
    switch delta {
    case -1: return .yesterday
    case 0: return .today
    case 1: return .tomorrow
    default: return nil
    }
  }
}

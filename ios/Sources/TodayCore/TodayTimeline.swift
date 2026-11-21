import CoreGraphics
import Foundation

public enum TodayTimeline {
  public enum Kind: Equatable, Sendable { case event, alarm, reminder }

  public struct Item: Equatable, Sendable {
    public let start: Date
    public let end: Date?
    public let kind: Kind
    public let isDone: Bool
    public let doneAtEntry: Bool

    public init(
      start: Date, end: Date? = nil, kind: Kind, isDone: Bool = false, doneAtEntry: Bool = false
    ) {
      self.start = start
      self.end = end
      self.kind = kind
      self.isDone = isDone
      self.doneAtEntry = doneAtEntry
    }

    public var stop: Date { max(start, end ?? start) }
  }

  public enum Row: Equatable, Hashable, Sendable {
    case item(Int)
    case free(Int)
    case now
  }

  public struct Frame: Equatable, Sendable {
    public let span: DateInterval
    public let minY: CGFloat
    public let maxY: CGFloat

    public init(span: DateInterval, minY: CGFloat, maxY: CGFloat) {
      self.span = span
      self.minY = minY
      self.maxY = maxY
    }
  }

  public static func isOpenPast(_ item: Item, now: Date?) -> Bool {
    guard let now else { return false }
    return item.kind == .reminder && !item.isDone && item.start < now
  }

  public static func isListed(_ item: Item, entry: Date?) -> Bool {
    guard let entry else { return true }
    if item.doneAtEntry { return false }
    return item.kind == .reminder || item.stop >= entry
  }

  public static func rows(items: [Item], free: [DateInterval], now: Date?, entry: Date?) -> [Row] {
    var entries: [(date: Date, rank: Int, order: Int, row: Row)] =
      items.indices.filter { isListed(items[$0], entry: entry) }.map {
        (items[$0].start, 0, $0, Row.item($0))
      } + free.indices.map { (free[$0].start, 1, $0, Row.free($0)) }
    entries.sort { ($0.date, $0.rank, $0.order) < ($1.date, $1.rank, $1.order) }
    var rows = entries.map(\.row)
    if let now {
      rows.insert(.now, at: entries.firstIndex { $0.date >= now } ?? entries.count)
    }
    return rows
  }

  public static func viewport(_ frames: [Frame], top: CGFloat, bottom: CGFloat, inset: CGFloat = 8)
    -> DateInterval?
  {
    let visible = frames.filter { $0.maxY > top + inset && $0.minY < bottom - inset }
    guard let start = visible.map(\.span.start).min(), let end = visible.map(\.span.end).max()
    else { return nil }
    return DateInterval(start: start, end: max(start, end))
  }

  public static func scrollTarget(for date: Date, in spans: [DateInterval]) -> Int? {
    spans.firstIndex { $0.end >= date } ?? (spans.isEmpty ? nil : spans.count - 1)
  }

  public static func ribbonRange(items: [Item], day: Date, calendar: Calendar) -> DateInterval {
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let six = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: dayStart) ?? dayStart
    let earliest = items.map(\.start).filter { $0 < dayEnd }.min()
    let early = earliest.flatMap { calendar.dateInterval(of: .hour, for: $0)?.start } ?? six
    let start = max(dayStart, min(six, early))
    return DateInterval(start: start, end: max(start, dayEnd))
  }

  public static func date(at fraction: Double, in range: DateInterval) -> Date {
    range.start.addingTimeInterval(min(max(fraction, 0), 1) * range.duration)
  }
}

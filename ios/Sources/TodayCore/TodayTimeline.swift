import CoreGraphics
import Foundation

public enum TodayTimeline {
  public enum Kind: Equatable, Sendable { case event, alarm, reminder }

  public struct Item: Equatable, Sendable {
    public let start: Date
    public let end: Date?
    public let kind: Kind
    public let isDone: Bool

    public init(start: Date, end: Date? = nil, kind: Kind, isDone: Bool = false) {
      self.start = start
      self.end = end
      self.kind = kind
      self.isDone = isDone
    }

    public var stop: Date { max(start, end ?? start) }
  }

  public enum Row: Equatable, Hashable, Sendable {
    case item(Int)
    case free(Int)
    case now
    case nowWithFree(Int)
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

  public static func isFinished(_ item: Item, now: Date?) -> Bool {
    guard let now else { return false }
    return item.kind == .reminder ? item.isDone : item.stop < now
  }

  public static func rows(items: [Item], free: [DateInterval], now: Date?) -> [Row] {
    let currentGap = now.flatMap { start in free.firstIndex { $0.start == start } }
    var entries: [(date: Date, rank: Int, order: Int, row: Row)] =
      items.indices.filter { !isFinished(items[$0], now: now) }.map {
        (items[$0].start, 0, $0, Row.item($0))
      }
      + free.indices.filter { $0 != currentGap }.map {
        (free[$0].start, 1, $0, Row.free($0))
      }
    entries.sort { ($0.date, $0.rank, $0.order) < ($1.date, $1.rank, $1.order) }
    var rows = entries.map(\.row)
    if let now {
      let marker = currentGap.map(Row.nowWithFree) ?? .now
      rows.insert(marker, at: entries.firstIndex { $0.date >= now } ?? entries.count)
    }
    return rows
  }

  public static func viewport(
    _ frames: some Sequence<Frame>, top: CGFloat, bottom: CGFloat, inset: CGFloat = 8
  ) -> DateInterval? {
    var bounds: (start: Date, end: Date)?
    for frame in frames
    where intersects(minY: frame.minY, maxY: frame.maxY, top: top, bottom: bottom, inset: inset) {
      let span = frame.span
      bounds = (
        min(bounds?.start ?? span.start, span.start), max(bounds?.end ?? span.end, span.end)
      )
    }
    return bounds.map { DateInterval(start: $0.start, end: $0.end) }
  }

  public struct Continuation: Equatable, Sendable {
    public let index: Int
    public let count: Int
  }

  public static let continuationHeight: CGFloat = 30

  public static func continuation(
    _ frames: [(minY: CGFloat, maxY: CGFloat)?], top: CGFloat, bottom: CGFloat
  ) -> Continuation? {
    let shown = frames.lastIndex { frame in
      guard let frame else { return false }
      return frame.maxY > top && frame.maxY <= bottom + 1
    }
    let next =
      shown.map { $0 + 1 }
      ?? frames.firstIndex { frame in
        guard let frame else { return false }
        return intersects(minY: frame.minY, maxY: frame.maxY, top: top, bottom: bottom)
      }
    guard let next, frames.indices.contains(next) else { return nil }
    return Continuation(index: next, count: frames.count - next)
  }

  package static func intersects(
    minY: CGFloat, maxY: CGFloat, top: CGFloat, bottom: CGFloat, inset: CGFloat = 8
  ) -> Bool {
    maxY > top + inset && minY < bottom - inset
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

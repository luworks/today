import Foundation

public enum TodayWindow {
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
    public var isCommitment: Bool { kind != .reminder }
  }

  public struct Heights: Equatable, Sendable {
    public let row: CGFloat
    public let now: CGFloat
    public let free: CGFloat

    public init(row: CGFloat, now: CGFloat, free: CGFloat) {
      self.row = row
      self.now = now
      self.free = free
    }
  }

  public enum Row: Equatable, Hashable, Sendable {
    case item(Int)
    case free(Int)
    case now
  }

  public struct Layout: Equatable, Sendable {
    public let rows: [Row]
    public let pinned: [Int]
    public let shown: [Int]
    public let later: [Int]
    public let commitment: Int?
    public let overflows: Bool
    public let scrolls: Bool
    public let windowEnd: Date
    public let height: CGFloat
  }

  public static func isOpenPast(_ item: Item, now: Date?) -> Bool {
    guard let now else { return false }
    return item.kind == .reminder && !item.isDone && item.start < now
  }

  public static func layout(
    items: [Item], free: [DateInterval] = [], now: Date?, start: Date, heights: Heights,
    available: CGFloat, dayEnd: Date
  ) -> Layout {
    let order = items.indices.sorted { (items[$0].start, $0) < (items[$1].start, $1) }
    let pinned = order.filter { isOpenPast(items[$0], now: now) }
    let showsDone = now.map { start < $0 } ?? false
    let candidates = order.filter {
      let item = items[$0]
      return !isOpenPast(item, now: now) && item.stop >= start && (showsDone || !item.isDone)
    }
    let windowHasNow = now.map { start <= $0 } ?? false
    var height = CGFloat(pinned.count) * heights.row + (windowHasNow ? heights.now : 0)
    let overflows = height + heights.row > available
    let cap = overflows ? height + available : available
    var count = 0
    while count < candidates.count && (height + heights.row <= cap || count == 0) {
      height += heights.row
      count += 1
    }
    let shown = Array(candidates.prefix(count))
    let later = Array(candidates.dropFirst(count))
    let nowIn: Bool = {
      guard windowHasNow, let now else { return false }
      if let first = later.first, items[first].start <= now { return false }
      return true
    }()
    if windowHasNow && !nowIn { height -= heights.now }
    let windowEnd: Date = {
      if let first = later.first {
        return max(items[first].start, start.addingTimeInterval(30 * 60))
      }
      return items.map(\.stop).reduce(dayEnd, max)
    }()
    var gaps: [Int] = []
    if !overflows {
      for index in free.indices.sorted(by: { (free[$0].start, $0) < (free[$1].start, $1) }) {
        let gap = free[index]
        guard gap.start >= start, gap.start < windowEnd else { continue }
        guard height + heights.free <= available else { break }
        height += heights.free
        gaps.append(index)
      }
    }
    var entries: [(date: Date, rank: Int, order: Int, row: Row)] =
      (pinned + shown).map { (items[$0].start, 0, $0, Row.item($0)) }
      + gaps.map { (free[$0].start, 1, $0, Row.free($0)) }
    entries.sort { ($0.date, $0.rank, $0.order) < ($1.date, $1.rank, $1.order) }
    var rows = entries.map(\.row)
    if nowIn, let now {
      let at = entries.firstIndex { $0.date >= now } ?? entries.count
      rows.insert(.now, at: at)
    }
    let commitment: Int? = {
      if overflows, let now {
        let soon = shown.first {
          let item = items[$0]
          return item.isCommitment && item.start >= now.addingTimeInterval(-3600) && item.stop > now
        }
        if let soon { return soon }
      }
      return later.first { items[$0].isCommitment }
    }()
    return Layout(
      rows: rows, pinned: pinned, shown: shown, later: later, commitment: commitment,
      overflows: overflows, scrolls: height > available, windowEnd: windowEnd, height: height)
  }

  public static func snapTargets(items: [Item], now: Date?) -> [Date] {
    var targets = Set(items.filter { !isOpenPast($0, now: now) }.map(\.start))
    if let now { targets.insert(now) }
    return targets.sorted()
  }

  public static func nearest(_ date: Date, in targets: [Date]) -> Date? {
    targets.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
  }

  public static func step(from date: Date, by direction: Int, in targets: [Date]) -> Date? {
    direction > 0 ? targets.first { $0 > date } : targets.last { $0 < date }
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

  public static func clamp(_ date: Date, in range: DateInterval) -> Date {
    let last = max(range.start, range.end.addingTimeInterval(-30 * 60))
    return min(max(date, range.start), last)
  }
}

public struct TodayRibbonScrub: Equatable, Sendable {
  private static let detentInterval: TimeInterval = 0.055
  private var crossed: Int?
  private var lastTick: TimeInterval?

  public init() {}

  public mutating func move(to position: Date, targets: [Date], at time: TimeInterval) -> Bool {
    let passed = targets.filter { $0 <= position }.count
    defer { crossed = passed }
    guard let crossed, crossed != passed else { return false }
    guard lastTick.map({ time - $0 >= Self.detentInterval }) ?? true else { return false }
    lastTick = time
    return true
  }

  public mutating func release(at time: TimeInterval) -> Bool {
    let settles = lastTick.map { time - $0 >= Self.detentInterval } ?? true
    self = TodayRibbonScrub()
    return settles
  }
}

import Foundation

// Pure logic with no SwiftData/SwiftUI, so it can be unit-tested with `swift test` (see ios/Eval).

public enum DayLabel {
  public static func text(for date: Date, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month().day())
  }

  /// "Today 15:00", or just "Today" when the time is midnight (a whole-day date).
  public static func withTime(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    if parts.hour == 0 && parts.minute == 0 { return text(for: date, calendar: calendar) }
    return text(for: date, calendar: calendar) + " "
      + date.formatted(date: .omitted, time: .shortened)
  }
}

/// How a task repeats. Completing a repeating task creates the next one (OmniFocus / Reminders style).
public enum RepeatRule: RawRepresentable, CaseIterable, Codable, Hashable, Sendable {
  case daily, weekdays, weekly, monthly, yearly
  /// Calendar weekday numbers (Sunday = 1). Callers must supply a nonempty subset of 1...7.
  case weeklyOn([Int])

  public static let allCases: [RepeatRule] = [.daily, .weekdays, .weekly, .monthly, .yearly]

  public static func choices(including rule: RepeatRule?) -> [RepeatRule] {
    guard let rule, !allCases.contains(rule) else { return allCases }
    return allCases + [rule]
  }

  public init?(rawValue: String) {
    switch rawValue {
    case "daily": self = .daily
    case "weekdays": self = .weekdays
    case "weekly": self = .weekly
    case "monthly": self = .monthly
    case "yearly": self = .yearly
    default:
      guard rawValue.hasPrefix("weekly:") else { return nil }
      let parts = rawValue.dropFirst("weekly:".count).split(
        separator: ",", omittingEmptySubsequences: false)
      // Accept only individual ASCII weekday digits; never silently drop malformed entries.
      guard !parts.isEmpty,
        parts.allSatisfy({ ["1", "2", "3", "4", "5", "6", "7"].contains(String($0)) })
      else { return nil }
      self = .weeklyOn(Set(parts.compactMap { Int($0) }).sorted())
    }
  }

  private static func canonicalDays(_ days: [Int]) -> [Int] {
    precondition(
      !days.isEmpty && days.allSatisfy { (1...7).contains($0) }, "Invalid weekly weekdays")
    return Set(days).sorted()
  }

  public var rawValue: String {
    switch self {
    case .daily: "daily"
    case .weekdays: "weekdays"
    case .weekly: "weekly"
    case .monthly: "monthly"
    case .yearly: "yearly"
    case .weeklyOn(let days):
      "weekly:" + Self.canonicalDays(days).map(String.init).joined(separator: ",")
    }
  }

  public static func == (lhs: RepeatRule, rhs: RepeatRule) -> Bool { lhs.rawValue == rhs.rawValue }

  public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let rule = Self(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid repeat rule: \(raw)")
    }
    self = rule
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var label: String {
    switch self {
    case .daily: return "Every day"
    case .weekdays: return "Every weekday"
    case .weekly: return "Every week"
    case .monthly: return "Every month"
    case .yearly: return "Every year"
    case .weeklyOn(let days):
      let selected = Self.canonicalDays(days)
      let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      return "Every "
        + [2, 3, 4, 5, 6, 7, 1].filter { selected.contains($0) }
        .map { names[$0 - 1] }.joined(separator: ", ")
    }
  }

  /// The next occurrence strictly after `date`, keeping its time of day.
  public func next(after date: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .daily:
      return calendar.date(byAdding: .day, value: 1, to: date) ?? date
    case .weekdays:
      var d = calendar.date(byAdding: .day, value: 1, to: date) ?? date
      while calendar.isDateInWeekend(d) {
        d = calendar.date(byAdding: .day, value: 1, to: d) ?? d
      }
      return d
    case .weekly:
      return calendar.date(byAdding: .day, value: 7, to: date) ?? date
    case .weeklyOn(let days):
      let selected = Self.canonicalDays(days)
      // Always add from the original clock time, so a DST adjustment on an intervening day cannot drift it.
      for offset in 1...7 {
        if let next = calendar.date(byAdding: .day, value: offset, to: date),
          next > date, selected.contains(calendar.component(.weekday, from: next))
        {
          return next
        }
      }
      return date
    case .monthly:
      return calendar.date(byAdding: .month, value: 1, to: date) ?? date
    case .yearly:
      return calendar.date(byAdding: .year, value: 1, to: date) ?? date
    }
  }
}

/// A checklist line inside a task.
public struct ChecklistItem: Codable, Hashable, Identifiable {
  public var id = UUID()
  public var title: String
  public var done = false

  public init(id: UUID = UUID(), title: String, done: Bool = false) {
    self.id = id
    self.title = title
    self.done = done
  }
}

public enum Recurrence {
  /// Start dates of an event's occurrences that overlap `interval`.
  public static func occurrences(
    start: Date, duration: TimeInterval, rule: RepeatRule?, in interval: DateInterval,
    calendar: Calendar = .current, limit: Int = 1000
  ) -> [Date] {
    let length = max(duration, 1)
    func overlaps(_ d: Date) -> Bool {
      d < interval.end && d.addingTimeInterval(length) > interval.start
    }
    guard let rule else { return overlaps(start) ? [start] : [] }
    var result: [Date] = []
    var d = start
    // Limit query results, not the age of the series. Historical occurrences must not exhaust the budget.
    // Advance with the repeat rule to preserve its calendar and DST semantics.
    while d < interval.end && result.count < limit {
      if overlaps(d) { result.append(d) }
      let next = rule.next(after: d, calendar: calendar)
      guard next > d else { break }
      d = next
    }
    return result
  }
}

/// Calendar entry date boundaries shared by the Week, Month and Year projections.
public enum CalendarEntryDates {
  public static func systemEnd(
    _ end: Date, isAllDay: Bool, forYearMarks: Bool,
    calendar: Calendar = .current
  ) -> Date {
    // EventKit already supplies the exclusive end, including 23/25-hour all-day dates.
    // Every view preserves it instead of extending the event into another day.
    return end
  }

  public static func overlaps(start: Date, end: Date, day: Date, calendar: Calendar = .current)
    -> Bool
  {
    guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
    if start == end { return start >= interval.start && start < interval.end }
    return start < interval.end && end > interval.start
  }
}

public enum DurationLabel {
  /// "25 min", "1 h", "1 h 30 min".
  public static func text(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) min" }
    let h = minutes / 60
    let m = minutes % 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
  }
}

/// Notification snoozes. A task's reminder fires once, at the reminder time: there are no follow-up nags (they put three
/// more alerts on the lock screen for the same task).
public enum ReminderPlan {
  /// Snooze presets offered on the notification.
  public static let snoozeMinutes = ["SNOOZE_10": 10, "SNOOZE_60": 60]

  public static func snoozed(_ action: String, now: Date) -> Date? {
    snoozeMinutes[action].map { now.addingTimeInterval(TimeInterval($0 * 60)) }
  }
}

/// The day view's single timeline: the free time shown between items.
public enum DaySchedule {
  /// Free time is counted from 08:00 (or now, on today) until 21:00.
  public static let openHour = 8, closeHour = 21
}

extension DaySchedule {
  /// Free time between items in waking hours (08:00, or now on today, until 21:00), at least `minimum` minutes.
  /// `busy` should already include the suggested slots, so a suggestion uses up its part of a gap.
  public static func freeGaps(
    busy: [DateInterval], day: Date, now: Date, minimum: Int = 30,
    calendar: Calendar = .current
  ) -> [DateInterval] {
    let dayStart = calendar.startOfDay(for: day)
    guard dayStart >= calendar.startOfDay(for: now),
      let open = calendar.date(bySettingHour: openHour, minute: 0, second: 0, of: dayStart),
      let close = calendar.date(bySettingHour: closeHour, minute: 0, second: 0, of: dayStart)
    else { return [] }
    var cursor = calendar.isDate(day, inSameDayAs: now) ? max(now, open) : open
    var gaps: [DateInterval] = []
    for block in busy.sorted(by: { $0.start < $1.start }) where block.end > cursor {
      if block.start >= close { break }
      if block.start > cursor { gaps.append(DateInterval(start: cursor, end: block.start)) }
      cursor = max(cursor, block.end)
    }
    if cursor < close { gaps.append(DateInterval(start: cursor, end: close)) }
    return gaps.filter { $0.duration >= TimeInterval(minimum * 60) }
  }

  /// "1 h 30 min", "45 min", "2 h".
  public static func freeLabel(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let h = minutes / 60
    let m = minutes % 60
    switch (h, m) {
    case (0, _): return "Free \(m) min"
    case (_, 0): return "Free \(h) h"
    default: return "Free \(h) h \(m) min"
    }
  }
}

/// Calendar tab: month grids, week starts and weekday letters. Follows the calendar's first weekday: the device setting, or the one chosen in Settings → Calendar (`Calendar.app`).
public enum CalendarMath {
  /// The month containing `date` as rows of 7 slots, like Apple's Month: nil before the 1st and after the last day.
  public static func monthWeeks(of date: Date, calendar: Calendar = .app) -> [[Date?]] {
    guard let first = calendar.dateInterval(of: .month, for: date)?.start,
      let count = calendar.range(of: .day, in: .month, for: first)?.count
    else { return [] }
    let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    var slots: [Date?] = Array(repeating: nil, count: lead)
    for i in 0..<count { slots.append(calendar.date(byAdding: .day, value: i, to: first)) }
    while slots.count % 7 != 0 { slots.append(nil) }
    return stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
  }

  /// First day of the month `offset` months away from the month of `reference`.
  public static func monthStart(offset: Int, from reference: Date, calendar: Calendar = .current)
    -> Date
  {
    let first = calendar.dateInterval(of: .month, for: reference)?.start ?? reference
    return calendar.date(byAdding: .month, value: offset, to: first) ?? first
  }

  /// How many months `date` is from `reference` (negative = earlier).
  public static func monthOffset(of date: Date, from reference: Date, calendar: Calendar = .current)
    -> Int
  {
    let a = calendar.dateComponents([.year, .month], from: reference)
    let b = calendar.dateComponents([.year, .month], from: date)
    return ((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 0) - (a.month ?? 0)
  }

  /// The week of the year `date` falls in (Settings > Calendar > "Show week numbers"), by the calendar's own rule for week 1.
  public static func weekNumber(of date: Date, calendar: Calendar = .app) -> Int {
    calendar.component(.weekOfYear, from: date)
  }

  /// One letter per weekday, starting at the calendar's first weekday ("S M T W T F S" on a Sunday-first device).
  public static func weekdayLetters(calendar: Calendar = .app) -> [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let i = calendar.firstWeekday - 1
    return Array(symbols[i...] + symbols[..<i])
  }

  /// Where the 1st of the month goes when you land on it: today inside the current month, else the 1st.
  public static func landingDay(
    inMonthOf month: Date, today: Date = .now, calendar: Calendar = .current
  ) -> Date {
    if calendar.isDate(month, equalTo: today, toGranularity: .month) {
      return calendar.startOfDay(for: today)
    }
    return calendar.dateInterval(of: .month, for: month)?.start ?? month
  }
}

/// Layout helpers for the 2 Day grid. Pure, so they can be tested.
public enum CalendarLayout {
  /// Where the timed things of one day column go. `blocks` are events (they have a duration); `marks` are reminders
  /// and alarm rings (a moment): one-line chips at their time, never a box of made-up length.
  /// A rectangle in a day column, in points (TodayCore is Foundation only, so not CGRect).
  public struct Frame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public func contains(x px: Double, y py: Double) -> Bool {
      px >= x && px < maxX && py >= y && py < maxY
    }
    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  public struct TimedDay: Equatable {
    /// One frame per block, in the input order, inside the column (1 pt in from each edge).
    public let blocks: [Frame]
    /// How deep each block is staggered: 0 sits at the left, deeper ones are indented and drawn on top.
    public let depths: [Int]
    /// One frame per mark, in the input order; nil when the mark is folded into the "+N" of the chip above it.
    public let marks: [Frame?]
    /// For each shown mark, the marks folded into it (empty for most).
    public let folded: [[Int]]
  }

  /// Lays out one day column, like Apple Calendar's day grids but readable when a day has many reminders:
  /// - A mark is a chip `chipHeight` tall at its time; a chip that would cover the one above moves down just enough.
  ///   A chip pushed more than `foldAfter` below its time folds into the "+N" of the chip it would sit under.
  /// - Events that start within `together` of each other share the width side by side; an event that starts later,
  ///   while an earlier one is still on, is indented and drawn over it, so both titles stay readable (Apple's stagger).
  /// - Where a chip runs beside an event, the event's group keeps the left half and the chip takes the right half.
  /// `blocks` and `marks` are y positions in points; marks are expected in time order.
  public static func timedDay(
    blocks: [(y: Double, height: Double)], marks: [Double], columnWidth: Double,
    chipHeight: Double = 18, foldAfter: Double = 36, together: Double = 18
  ) -> TimedDay {
    let content = max(0, columnWidth - 2)

    // Marks: stack downwards, fold what would drift too far from its time.
    var markY = [Double?](repeating: nil, count: marks.count)
    var folded = [[Int]](repeating: [], count: marks.count)
    var head: Int?
    var lastY = -Double.infinity
    for (i, y) in marks.enumerated() {
      let placed = max(y, lastY + chipHeight + 1)
      if let h = head, placed - y > foldAfter {
        folded[h].append(i)
        continue
      }
      markY[i] = placed
      lastY = placed
      head = i
    }

    // Blocks: groups of events that start together; a later overlapping group goes one level deeper.
    struct Group {
      var top: Double
      var bottom: Double
      var members: [Int]
      var depth: Int
    }
    var groups: [Group] = []
    var groupOf = [Int](repeating: 0, count: blocks.count)
    let order = blocks.indices.sorted { (blocks[$0].y, $0) < (blocks[$1].y, $1) }
    for i in order {
      let b = blocks[i]
      if let g = groups.indices.last(where: {
        b.y - groups[$0].top < together && groups[$0].bottom > b.y
      }) {
        groups[g].members.append(i)
        groups[g].bottom = max(groups[g].bottom, b.y + b.height)
        groupOf[i] = g
      } else {
        let under = groups.filter { $0.bottom > b.y }.map(\.depth).max() ?? -1
        groups.append(Group(top: b.y, bottom: b.y + b.height, members: [i], depth: under + 1))
        groupOf[i] = groups.count - 1
      }
    }

    func meets(_ y: Double, _ g: Group) -> Bool {
      y < g.bottom - 0.5 && g.top < y + chipHeight - 0.5
    }
    let shownY = markY.compactMap { $0 }
    let halved = groups.map { g in shownY.contains { meets($0, g) } }

    var rects = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: blocks.count)
    var depths = [Int](repeating: 0, count: blocks.count)
    for (g, group) in groups.enumerated() {
      let area: Double = halved[g] ? content / 2 : content
      let indent: Double = min(44, area * 0.4)
      let left: Double = min(Double(group.depth) * indent, area * 0.6)
      let share: Double = (area - left) / Double(group.members.count)
      let width: Double = min(share, max(8, share - 1))
      for (k, i) in group.members.enumerated() {
        let x: Double = 1 + left + share * Double(k)
        rects[i] = Frame(x: x, y: blocks[i].y, width: width, height: blocks[i].height)
        depths[i] = group.depth
      }
    }

    let half: Double = content / 2
    let markRects: [Frame?] = markY.map { y -> Frame? in
      guard let y else { return nil }
      if groups.contains(where: { meets(y, $0) }) {
        return Frame(x: 2 + half, y: y, width: half - 1, height: chipHeight)
      }
      return Frame(x: 1, y: y, width: content, height: chipHeight)
    }
    return TimedDay(blocks: rects, depths: depths, marks: markRects, folded: folded)
  }

  /// Lane (row) for each banner in the all-day strip. `spans` are inclusive day columns (any day numbering, e.g. days from today).
  /// Banners that overlap in days never share a lane; earlier and longer banners go first.
  public static func lanes(for spans: [(start: Int, end: Int)]) -> [Int] {
    let order = spans.indices.sorted {
      (spans[$0].start, spans[$1].end - spans[$1].start, $0) < (
        spans[$1].start, spans[$0].end - spans[$0].start, $1
      )
    }
    var laneEnds: [Int] = []  // last column used in each lane
    var result = Array(repeating: 0, count: spans.count)
    for i in order {
      if let lane = laneEnds.firstIndex(where: { $0 < spans[i].start }) {
        laneEnds[lane] = spans[i].end
        result[i] = lane
      } else {
        laneEnds.append(spans[i].end)
        result[i] = laneEnds.count - 1
      }
    }
    return result
  }

  /// The slot under a point on the 2 Day grid, for a long-press that makes a new event: the day column and the start
  /// minute, snapped down to 15 minutes like Apple Calendar. `x` and `y` are in the grid's space (hour 0 at y = 0,
  /// the hour labels in the first `gutter` points). Clamped to the visible days and to a start no later than 23:45.
  public static func slot(
    x: Double, y: Double, gutter: Double, columnWidth: Double, hourHeight: Double, dayCount: Int
  ) -> (day: Int, minute: Int) {
    let day = min(max(Int(((x - gutter) / columnWidth).rounded(.down)), 0), dayCount - 1)
    let minute = Int((y / hourHeight * 60 / 15).rounded(.down)) * 15
    return (day, min(max(minute, 0), 24 * 60 - 15))
  }

  /// Hour heights the 2 Day grid can be pinched to, in points: compact enough for a whole day, roomy enough to read short events.
  public static let hourHeights: ClosedRange<Double> = 28...120

  /// The hour height after a pinch of `scale` that started at `start`, kept inside `hourHeights`.
  public static func zoomedHourHeight(_ start: Double, scale: Double) -> Double {
    min(max(start * scale, hourHeights.lowerBound), hourHeights.upperBound)
  }
}

public enum ListName {
  /// "01 工作" → "工作". Numbered names keep their order for sorting; the number is noise when shown.
  public static func display(_ name: String) -> String {
    guard let r = name.range(of: #"^\d{1,3}[\s._-]+"#, options: .regularExpression) else {
      return name
    }
    let rest = name[r.upperBound...]
    return rest.isEmpty ? name : String(rest)
  }

  /// 1 for "01 工作", nil for names without a number prefix.
  public static func number(_ name: String) -> Int? {
    guard let r = name.range(of: #"^\d{1,3}(?=[\s._-])"#, options: .regularExpression) else {
      return nil
    }
    return Int(name[r])
  }
}

/// Real alarms (AlarmKit): which day they ring and how to label the repeat.
public enum AlarmPlan {
  /// The next time hour:minute occurs after `date` on an allowed weekday (any day when `weekdays` is empty).
  public static func nextFire(
    hour: Int, minute: Int, weekdays: [Int], after date: Date, calendar: Calendar = .current
  ) -> Date? {
    let start = calendar.startOfDay(for: date)
    for offset in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: offset, to: start),
        let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
        candidate > date
      else { continue }
      if weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: candidate)) {
        return candidate
      }
    }
    return nil
  }

  /// When the alarm rings on `day`: a repeating alarm on its weekdays, a one-time alarm on the day of its next occurrence.
  public static func fire(
    on day: Date, hour: Int, minute: Int, weekdays: [Int], now: Date, calendar: Calendar = .current
  ) -> Date? {
    if weekdays.isEmpty {
      guard
        let next = nextFire(
          hour: hour, minute: minute, weekdays: [], after: now, calendar: calendar),
        calendar.isDate(next, inSameDayAs: day)
      else { return nil }
      return next
    }
    guard weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
  }

  // MARK: Apple Clock wording

  /// Clock's name for an alarm with no label.
  public static let defaultLabel = "Alarm"

  /// Weekdays in the order the calendar shows them (Sunday first in the US, Monday first in most of Europe).
  public static func orderedWeekdays(calendar: Calendar = .current) -> [Int] {
    (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
  }

  /// The repeat value the way Clock words it: "Never", "Every day", "Weekdays", "Weekends", "Every Monday" for one day,
  /// otherwise short day names where three or more days in a row become a range: "Sun–Thu", "Mon, Wed, Fri", "Mon–Wed, Fri".
  /// "In a row" follows the calendar's own week order (Sunday first in the US, Monday first in most of Europe).
  public static func repeatValue(weekdays: [Int], calendar: Calendar = .current) -> String {
    let set = Set(weekdays)
    if set.isEmpty { return "Never" }
    if set.count == 7 { return "Every day" }
    if set == [2, 3, 4, 5, 6] { return "Weekdays" }
    if set == [1, 7] { return "Weekends" }
    let order = orderedWeekdays(calendar: calendar)
    let days = order.filter(set.contains)
    if days.count == 1 { return "Every " + calendar.weekdaySymbols[days[0] - 1] }
    var runs: [[Int]] = []
    for day in days {
      if let last = runs.last?.last, let a = order.firstIndex(of: last),
        order.firstIndex(of: day) == a + 1
      {
        runs[runs.count - 1].append(day)
      } else {
        runs.append([day])
      }
    }
    let name = { (day: Int) in calendar.shortWeekdaySymbols[day - 1] }
    return runs.flatMap { run in
      run.count >= 3 ? [name(run[0]) + "\u{2013}" + name(run[run.count - 1])] : run.map(name)
    }.joined(separator: ", ")
  }

  /// The alarm wheel's minute step: rows 00, 05 … 55.
  public static let wheelMinuteStep = 5

  /// The minute column's step for an alarm at `minute` (nil = a new alarm): `wheelMinuteStep`, or 1 when the
  /// minute is off that grid (7:42), so opening and saving the alarm never moves its minute.
  public static func minuteStep(forAlarmMinute minute: Int?) -> Int {
    (minute ?? 0) % wheelMinuteStep == 0 ? wheelMinuteStep : 1
  }

  /// The next five-minute mark after `date` (10:56 → 11:00, 10:41 → 10:45): where Add Alarm opens, on the
  /// alarm wheel's five-minute minute column.
  public static func nextFiveMinutes(after date: Date, calendar: Calendar = .current) -> Date {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let next = ((c.minute ?? 0) / wheelMinuteStep + 1) * wheelMinuteStep
    let base =
      calendar.date(
        from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: 0))
      ?? date
    return calendar.date(byAdding: .minute, value: next, to: base) ?? date
  }

  /// The line under the time in the list: the label (or "Alarm"), then the repeat when there is one.
  /// "Alarm", "Alarm, Every day", "Wake up, Weekdays".
  public static func rowSubtitle(label: String, weekdays: [Int], calendar: Calendar = .current)
    -> String
  {
    let name = label.trimmingCharacters(in: .whitespaces)
    let head = name.isEmpty ? defaultLabel : name
    return weekdays.isEmpty
      ? head : head + ", " + repeatValue(weekdays: weekdays, calendar: calendar)
  }

  /// The time the way the user's clock shows it, split so the AM/PM can be set small:
  /// ("7:05", "AM") on a 12-hour clock, ("07:05", nil) on a 24-hour one.
  public static func timeParts(hour: Int, minute: Int, locale: Locale = .current) -> (
    time: String, suffix: String?
  ) {
    let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
    let mm = String(format: "%02d", minute)
    guard pattern.contains("a") else { return (String(format: "%02d:", hour) + mm, nil) }
    let f = DateFormatter()
    f.locale = locale
    let h = hour % 12 == 0 ? 12 : hour % 12
    return ("\(h):" + mm, hour < 12 ? f.amSymbol : f.pmSymbol)
  }

  /// When an alarm will next ring, or nil when it won't: a repeating alarm at its next weekday, a
  /// one-time alarm at its next occurrence after it was last switched on, unless that has already passed.
  public static func nextRing(
    hour: Int, minute: Int, weekdays: [Int], switchedOn: Date, now: Date,
    calendar: Calendar = .current
  ) -> Date? {
    if weekdays.isEmpty {
      guard
        let ring = nextFire(
          hour: hour, minute: minute, weekdays: [], after: switchedOn, calendar: calendar),
        ring > now
      else { return nil }
      return ring
    }
    return nextFire(hour: hour, minute: minute, weekdays: weekdays, after: now, calendar: calendar)
  }

  /// "7 hr 12 min", "12 min", "2 days 3 hr": how long until `date`, rounded up to the minute.
  public static func intervalText(from now: Date, to date: Date) -> String {
    let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    let days = minutes / 1440
    let hours = minutes % 1440 / 60
    let mins = minutes % 60
    if days > 0 {
      return "\(days) \(days == 1 ? "day" : "days")" + (hours > 0 ? " \(hours) hr" : "")
    }
    if hours > 0 { return "\(hours) hr" + (mins > 0 ? " \(mins) min" : "") }
    return "\(mins) min"
  }

  /// "Next alarm in 7 hr 12 min", or nil when nothing will ring.
  public static func nextAlarmText(rings: [Date], now: Date) -> String? {
    guard let next = rings.filter({ $0 > now }).min() else { return nil }
    return "Next alarm in " + intervalText(from: now, to: next)
  }

  /// What Clock calls "Snooze": nine minutes.
  public static let snoozeSeconds: TimeInterval = 9 * 60

  /// Snooze Duration choices in the alarm editor, in minutes.
  public static let snoozeChoices = [5, 9, 10, 15, 30]
  /// Default Snooze Duration (Clock's nine minutes).
  public static let defaultSnoozeMinutes = 9

  /// The allowed Snooze Duration nearest to `minutes` (ties go to the shorter one), so alarms saved with a
  /// value no longer offered (1, 3, 7, 20…) keep working: 1/3/7 → 5, 20 → 15, 45 → 30.
  public static func snoozeMinutes(nearest minutes: Int) -> Int {
    snoozeChoices.min { a, b in
      let da = abs(a - minutes)
      let db = abs(b - minutes)
      return da != db ? da < db : a < b
    } ?? defaultSnoozeMinutes
  }
}

/// Search matching: every word of the query must appear in one of the fields; case, accents and width are ignored.
public enum SearchMatch {
  public static func matches(_ query: String, in fields: [String]) -> Bool {
    let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !words.isEmpty else { return false }
    return words.allSatisfy { word in
      fields.contains {
        $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
          != nil
      }
    }
  }
}

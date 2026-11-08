import Foundation

// Shared by the app (writes the snapshot) and the TodayWidgets extension (reads it).
// Foundation only: no SwiftData, SwiftUI or WidgetKit, so `swift test` can cover it on macOS.

/// One thing on the widget: an event, a reminder with a time, or an alarm.
public struct WidgetItem: Codable, Hashable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case event, reminder, alarm }

  public var id: String
  public var title: String
  /// For all-day items: the start of their day.
  public var start: Date
  /// Events only. While an event is in progress it stays on the widget; reminders and alarms leave at their start.
  public var end: Date?
  public var isAllDay: Bool
  public var kind: Kind
  /// Set for events that live in Apple Calendar (system events and Today's events mirrored there). When the widget can
  /// read EventKit itself it drops these and shows the live copies instead. Optional so older snapshots still decode.
  public var externalID: String?
  /// Events with a location, when Travel time is on and the app has an estimate: driving minutes and when to leave.
  /// Optional so older snapshots still decode.
  public var travelMinutes: Int?
  public var leaveBy: Date?
  /// True on a later day's row of an event that began on an earlier day: `start` is that day's midnight, not a real start.
  public var startedEarlier: Bool?

  public init(
    id: String, title: String, start: Date, end: Date? = nil, isAllDay: Bool = false, kind: Kind,
    externalID: String? = nil,
    travelMinutes: Int? = nil, leaveBy: Date? = nil, startedEarlier: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.kind = kind
    self.externalID = externalID
    self.travelMinutes = travelMinutes
    self.leaveBy = leaveBy
    self.startedEarlier = startedEarlier
  }

  /// "Drive 18 min · Leave by 14:20" for this item at `now`, or nil without an estimate.
  public func travelText(now: Date, time: (Date) -> String) -> String? {
    guard let travelMinutes, let leaveBy, start > now else { return nil }
    return
      "Drive \(TravelTime.durationText(seconds: Double(travelMinutes) * 60)) · \(TravelTime.leaveText(leaveBy: leaveBy, now: now, time: time))"
  }

  /// An event's rows on `days`, the way the Calendar tab reads them: clipped to each day it overlaps, and all-day on a day
  /// it covers completely (the middle of a multi-day event). `end` is exclusive (for all-day events: the midnight after).
  public static func eventRows(
    id: String, title: String, start: Date, end: Date, isAllDay: Bool, externalID: String?,
    days: [Date], calendar: Calendar = .current
  ) -> [WidgetItem] {
    days.compactMap { day in
      guard let interval = calendar.dateInterval(of: .day, for: day),
        start < interval.end && end > interval.start || (start == end && interval.contains(start))
      else { return nil }
      let allDay = isAllDay || start <= interval.start && end >= interval.end
      let s = max(start, interval.start)
      let e = min(end, interval.end)
      return WidgetItem(
        id: "\(id)#\(Int(interval.start.timeIntervalSince1970))", title: title,
        start: allDay ? interval.start : s, end: allDay ? nil : e,
        isAllDay: allDay, kind: .event, externalID: externalID,
        startedEarlier: start < interval.start ? true : nil)
    }
  }
}

/// What the app hands the widget: the items of the next `WidgetSnapshot.days` days (so the "Tomorrow" line still has data
/// after midnight), written as JSON into the App Group container.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var items: [WidgetItem]
  /// The app's Apple Calendar settings, which the widget needs to read EventKit the way the app does:
  /// nil in snapshots from older builds (then the widget shows the snapshot as it is).
  public var calendar: CalendarSettings?
  /// Apple Calendar occurrences settled today (`NextItems.occurrenceKey`). The widget reads those events live, so it
  /// needs this to keep them off too. Optional so older snapshots still decode.
  public var settledEvents: [String]?

  public struct CalendarSettings: Codable, Equatable, Sendable {
    /// Apple Calendar is on in Today and access is granted.
    public var isOn: Bool
    /// Calendars turned off in the Calendars list.
    public var hiddenCalendarIDs: [String]

    public init(isOn: Bool, hiddenCalendarIDs: [String]) {
      self.isOn = isOn
      self.hiddenCalendarIDs = hiddenCalendarIDs
    }
  }

  public init(
    generatedAt: Date, items: [WidgetItem], calendar: CalendarSettings? = nil,
    settledEvents: [String]? = nil
  ) {
    self.generatedAt = generatedAt
    self.items = items
    self.calendar = calendar
    self.settledEvents = settledEvents
  }

  /// Today, tomorrow and the day after: at 00:05 "today" is the old tomorrow and "Tomorrow" is the old day after.
  public static let days = 3

  public static let appGroup = "group.com.luworks.today"
  public static let fileName = "widget-snapshot.json"

  public static var fileURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent(fileName)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) -> WidgetSnapshot? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(WidgetSnapshot.self, from: data)
  }

  /// The last snapshot the app wrote, or nil (no App Group access, or the app never ran).
  public static func load() -> WidgetSnapshot? {
    guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
    return decode(data)
  }

  /// Writes the snapshot atomically. Returns false when the App Group container is unavailable.
  @discardableResult
  public func save() -> Bool {
    guard let url = Self.fileURL, let data = try? encoded() else { return false }
    return (try? data.write(to: url, options: .atomic)) != nil
  }
}

/// What the widgets show at one moment.
public struct NextUp: Equatable {
  /// The next items today (all-day first, then by time), at most `limit`.
  public var today: [WidgetItem]
  /// How many items are left today, including the ones in `today`.
  public var remainingToday: Int
  /// The first item tomorrow; only set when nothing is left today.
  public var tomorrow: WidgetItem?

  public init(today: [WidgetItem], remainingToday: Int, tomorrow: WidgetItem? = nil) {
    self.today = today
    self.remainingToday = remainingToday
    self.tomorrow = tomorrow
  }
}

/// Widget deep links: `today://today` opens the Today tab; `today://today?day=2026-10-16` opens Today on that day.
public enum WidgetLink {
  public static let scheme = "today"

  public static func url(day: Date? = nil, calendar: Calendar = .current) -> URL {
    var c = URLComponents()
    c.scheme = scheme
    c.host = "today"
    if let day {
      let d = calendar.dateComponents([.year, .month, .day], from: day)
      c.queryItems = [
        URLQueryItem(
          name: "day",
          value: String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0))
      ]
    }
    return c.url ?? URL(string: "today://today")!
  }

  /// nil when the URL isn't a Today link. A link without a valid day means today.
  public static func day(from url: URL, now: Date = .now, calendar: Calendar = .current) -> Date? {
    guard url.scheme == scheme, url.host == "today" else { return nil }
    let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "day"
    }?.value
    let parts = (value ?? "").split(separator: "-").compactMap { Int($0) }
    if parts.count == 3,
      let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    {
      return calendar.startOfDay(for: day)
    }
    return calendar.startOfDay(for: now)
  }
}

public enum NextItems {
  /// What the widget shows: the snapshot, with its Apple Calendar events replaced by `live` ones read from EventKit
  /// just now. `live == nil` (no access, or Apple Calendar is off) keeps the snapshot as it is. Today's own events,
  /// reminders and alarms always come from the snapshot.
  /// `settledEvents` stay off even though EventKit still has them.
  public static func merge(
    snapshot: [WidgetItem], live: [WidgetItem]?, settledEvents: [String] = []
  ) -> [WidgetItem] {
    guard var live else { return snapshot }
    if !settledEvents.isEmpty {
      let settled = Set(settledEvents)
      live.removeAll { item in
        item.externalID.map { settled.contains(occurrenceKey($0, item.start)) } ?? false
      }
    }
    // The widget can't compute travel time (no location, no network): keep the app's estimate on the live copy
    // of the same occurrence (same Apple Calendar event, same start).
    var travel: [String: WidgetItem] = [:]
    for item in snapshot where item.kind == .event && item.leaveBy != nil {
      if let id = item.externalID { travel[occurrenceKey(id, item.start)] = item }
    }
    let carried = live.map { item -> WidgetItem in
      guard let id = item.externalID, let from = travel[occurrenceKey(id, item.start)] else {
        return item
      }
      var copy = item
      copy.travelMinutes = from.travelMinutes
      copy.leaveBy = from.leaveBy
      return copy
    }
    return (snapshot.filter { $0.kind != .event || $0.externalID == nil } + carried).sorted(
      by: ordered)
  }

  /// What the card and every widget may show: `items` without the ones settled today, so the next item moves up and
  /// "+N" does not count them. `settledEvents` are the removed Apple Calendar occurrences, for `merge`.
  public static func removingSettled(_ items: [WidgetItem], settledIDs: Set<String>) -> (
    items: [WidgetItem], settledEvents: [String]
  ) {
    guard !settledIDs.isEmpty else { return (items, []) }
    let settled = items.filter { settledIDs.contains($0.id) }
    let keys = settled.compactMap { item in
      item.externalID.map { occurrenceKey($0, item.start) }
    }
    return (items.filter { !settledIDs.contains($0.id) }, Array(Set(keys)).sorted())
  }

  static func occurrenceKey(_ externalID: String, _ start: Date) -> String {
    "\(externalID)@\(Int(start.timeIntervalSince1970))"
  }

  /// Still worth showing at `now`: all-day items for their whole day, events until they end, the rest until they start.
  public static func isLeft(_ item: WidgetItem, now: Date, calendar: Calendar = .current) -> Bool {
    if item.isAllDay { return calendar.isDate(item.start, inSameDayAs: now) }
    // Strictly after: the timeline has an entry at each start, and that entry must drop a reminder or alarm.
    return item.start > now || (item.end ?? item.start) > now
  }

  /// Apple's order: all-day first, then by start, then by title.
  public static func ordered(_ a: WidgetItem, _ b: WidgetItem) -> Bool {
    if a.isAllDay != b.isAllDay { return a.isAllDay }
    if a.start != b.start { return a.start < b.start }
    return a.title.localizedStandardCompare(b.title) == .orderedAscending
  }

  public static func select(
    from items: [WidgetItem], now: Date, calendar: Calendar = .current, limit: Int = 3
  ) -> NextUp {
    let left =
      items
      .filter {
        calendar.isDate($0.start, inSameDayAs: now) && isLeft($0, now: now, calendar: calendar)
      }
      .sorted(by: ordered)
    var tomorrow: WidgetItem?
    if left.isEmpty, let next = calendar.date(byAdding: .day, value: 1, to: now) {
      tomorrow =
        items.filter { calendar.isDate($0.start, inSameDayAs: next) }.sorted(by: ordered).first
    }
    return NextUp(
      today: Array(left.prefix(max(0, limit))), remainingToday: left.count, tomorrow: tomorrow)
  }

  /// When the widget should redraw: now, every start and end still ahead, and each midnight (where tomorrow's items
  /// become today's), for `days` days. Running past tonight's midnight keeps the widget right if iOS delays the reload.
  /// `countdownLead`: also a date that long before each start, where the Lock Screen widget starts its live countdown.
  public static func timelineDates(
    for items: [WidgetItem], now: Date, days: Int = 1, countdownLead: TimeInterval? = nil,
    calendar: Calendar = .current
  ) -> [Date] {
    let today = calendar.startOfDay(for: now)
    let midnights = (1...max(1, days)).compactMap {
      calendar.date(byAdding: .day, value: $0, to: today)
    }
    let last = midnights.last ?? now.addingTimeInterval(86_400)
    var dates = Set([now] + midnights)
    for item in items where !item.isAllDay {
      // The leave-by time too, where "Leave by 14:20" turns into "Leave now".
      let lead = countdownLead.map { item.start.addingTimeInterval(-$0) }
      for d in [item.start, item.end, item.leaveBy, lead].compactMap({ $0 })
      where d > now && d < last {
        dates.insert(d)
      }
    }
    return dates.sorted()
  }

  /// When the widget asks for a new timeline: within `interval` (to re-read Apple Calendar), and never after midnight.
  public static func reloadDate(
    now: Date, interval: TimeInterval = 3600, calendar: Calendar = .current
  ) -> Date {
    let midnight =
      calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
      ?? now.addingTimeInterval(86_400)
    return min(now.addingTimeInterval(interval), midnight)
  }
}

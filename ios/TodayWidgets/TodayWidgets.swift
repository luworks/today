import EventKit
import SwiftUI
import TodayShared
import WidgetKit
import os

// "Next up": the next three things today (events, reminders with a time, alarms), for the Lock Screen and Home Screen.
// The widget reads the JSON snapshot the app writes into the App Group (see Shared/WidgetSnapshot.swift) and, when it may,
// Apple Calendar itself, so events added there show up without opening the app.

@main
struct TodayWidgetsBundle: WidgetBundle {
  var body: some Widget {
    NextUpWidget()
    AlarmLiveActivity()
    UpNextLiveActivity()
  }
}

struct NextUpWidget: Widget {
  let kind = "TodayNextUp"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NextUpProvider()) { entry in
      NextUpView(entry: entry)
    }
    .configurationDisplayName("Next Up")
    .description("The next three things today: events, reminders and alarms.")
    .supportedFamilies([
      .accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall, .systemMedium,
    ])
  }
}

// MARK: Timeline

struct NextUpEntry: TimelineEntry {
  let date: Date
  let items: [WidgetItem]

  var next: NextUp { NextItems.select(from: items, now: date) }
  /// Items on this entry's day (left or not), for the circular gauge.
  var totalToday: Int {
    items.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }.count
  }
}

struct NextUpProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextUpEntry {
    NextUpEntry(date: .now, items: Self.sample(now: .now))
  }

  func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
    let items = Self.currentItems(now: .now)
    // The widget gallery shows sample items when the app hasn't written anything yet.
    completion(
      NextUpEntry(
        date: .now, items: context.isPreview && items.isEmpty ? Self.sample(now: .now) : items))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
    let now = Date.now
    let items = Self.currentItems(now: now)
    // One entry at each start and end, so the list advances by itself, through tomorrow in case iOS delays the reload.
    // Reload hourly (and at midnight) to re-read Apple Calendar.
    let entries = NextItems.timelineDates(
      for: items, now: now, days: 2, countdownLead: LockScreenNext.countdownWindow
    ).map { NextUpEntry(date: $0, items: items) }
    // The widget never opens the Activity database: it leaves one small file in the App Group outbox for the app to import.
    ActivityOutbox.append(
      kind: "sys.widget.refresh", actor: "system", channel: "widget", props: ["count": items.count],
      at: now)
    completion(Timeline(entries: entries, policy: .after(NextItems.reloadDate(now: now))))
  }

  /// The app's snapshot, with its Apple Calendar events replaced by the ones in Apple Calendar right now.
  static func currentItems(now: Date) -> [WidgetItem] {
    let snapshot = WidgetSnapshot.load()
    return NextItems.merge(
      snapshot: snapshot?.items ?? [], live: liveEvents(settings: snapshot?.calendar, now: now),
      settledEvents: snapshot?.settledEvents ?? [])
  }

  /// One store for the extension's lifetime: creating an EKEventStore is slow.
  // All EventKit access is serialized; only immutable WidgetItem values leave this lock.
  private static let eventStore = OSAllocatedUnfairLock(uncheckedState: EKEventStore())

  /// Apple Calendar events for the snapshot's days, read the way the app reads them (same visible calendars).
  /// nil when the widget can't or shouldn't read them: an app build that doesn't say how, Apple Calendar off in Today,
  /// or no full access for the extension. Then the snapshot's copies are used.
  static func liveEvents(
    settings: WidgetSnapshot.CalendarSettings?, now: Date, calendar: Calendar = .current
  ) -> [WidgetItem]? {
    guard let settings, settings.isOn, EKEventStore.authorizationStatus(for: .event) == .fullAccess
    else { return nil }
    return eventStore.withLock { store in
      let today = calendar.startOfDay(for: now)
      let days = (0..<WidgetSnapshot.days).compactMap {
        calendar.date(byAdding: .day, value: $0, to: today)
      }
      guard let end = calendar.date(byAdding: .day, value: WidgetSnapshot.days, to: today) else {
        return nil
      }
      let hidden = Set(settings.hiddenCalendarIDs)
      var visible: [EKCalendar]?
      if !hidden.isEmpty {
        visible = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        if visible?.isEmpty == true { return [] }
      }
      let predicate = store.predicateForEvents(withStart: today, end: end, calendars: visible)
      return store.events(matching: predicate).flatMap { e -> [WidgetItem] in
        let id = e.eventIdentifier ?? UUID().uuidString
        var end: Date = e.endDate
        // EventKit ends an all-day event on its last day; make the end exclusive, as the app does.
        if e.isAllDay {
          end =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e.endDate))
            ?? e.endDate
        }
        return WidgetItem.eventRows(
          id: "\(id)@\(e.startDate.timeIntervalSince1970)", title: e.title ?? "Untitled",
          start: e.startDate, end: end, isAllDay: e.isAllDay, externalID: id,
          days: days, calendar: calendar)
      }
    }
  }

  static func sample(now: Date) -> [WidgetItem] {
    let base =
      Calendar.current.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(3600)) ?? now
    return [
      WidgetItem(
        id: "s1", title: "Team standup", start: base, end: base.addingTimeInterval(900),
        kind: .event),
      WidgetItem(
        id: "s2", title: "Call Alex", start: base.addingTimeInterval(5400), kind: .reminder),
      WidgetItem(
        id: "s3", title: "Dentist", start: base.addingTimeInterval(10800),
        end: base.addingTimeInterval(14400), kind: .event,
        travelMinutes: 18, leaveBy: base.addingTimeInterval(10800 - 18 * 60)),
    ]
  }
}

// MARK: Views

struct NextUpView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NextUpEntry

  var body: some View {
    content
      .widgetURL(WidgetLink.url())
  }

  @ViewBuilder private var content: some View {
    switch family {
    case .accessoryRectangular:
      RectangularView(entry: entry).containerBackground(for: .widget) { Color.clear }
    case .accessoryCircular:
      CircularView(entry: entry).containerBackground(for: .widget) { Color.clear }
    case .accessoryInline:
      InlineView(entry: entry).containerBackground(for: .widget) { Color.clear }
    case .systemMedium: MediumView(entry: entry).containerBackground(.background, for: .widget)
    default: SmallView(entry: entry).containerBackground(.background, for: .widget)
    }
  }
}

/// "14:20" in the user's 12/24-hour setting, for "Leave by 14:20".
func shortTime(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

/// "15:00" (in the user's 12/24-hour setting) or "All day".
struct TimeText: View {
  let item: WidgetItem
  var body: some View {
    if item.isAllDay {
      Text("All day")
    } else {
      Text(item.start, format: .dateTime.hour().minute())
    }
  }
}

extension WidgetItem.Kind {
  var symbol: String {
    switch self {
    case .event: "calendar"
    case .reminder: "circle"
    case .alarm: "alarm"
    }
  }
}

/// Under the clock: the next item only, "15:00 · in 25 min" and its title on up to two lines (half-width safe).
struct RectangularView: View {
  let entry: NextUpEntry

  var body: some View {
    LockScreenNextView(
      model: LockScreenNext.make(items: entry.items, now: entry.date, time: shortTime))
  }
}

/// A ring of how much of today is done, with the next item's time in the middle.
struct CircularView: View {
  let entry: NextUpEntry

  var body: some View {
    let next = entry.next
    if let item = next.today.first {
      let total = max(entry.totalToday, next.remainingToday, 1)
      Gauge(value: Double(total - next.remainingToday), in: 0...Double(total)) {
        Image(systemName: item.kind.symbol)
      } currentValueLabel: {
        TimeText(item: item)
          .font(.system(.body, design: .rounded).weight(.semibold))
          .monospacedDigit()
          .minimumScaleFactor(0.5)
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .widgetAccentable()
      .accessibilityLabel(Text("Next: \(item.title). \(next.remainingToday) left today."))
    } else {
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "checkmark")
          .font(.title2.weight(.semibold))
          .widgetAccentable()
      }
      .accessibilityLabel("Nothing else today")
    }
  }
}

/// Above the clock: "15:00 Dentist".
struct InlineView: View {
  let entry: NextUpEntry

  var body: some View {
    if let item = entry.next.today.first {
      if item.isAllDay {
        Text("All day \(item.title)")
      } else {
        Text("\(Text(item.start, format: .dateTime.hour().minute())) \(item.title)")
      }
    } else {
      Text("Nothing else today")
    }
  }
}

/// Home Screen small: the next item, its time and how long until it starts.
struct SmallView: View {
  let entry: NextUpEntry

  var body: some View {
    let next = entry.next
    VStack(alignment: .leading, spacing: 4) {
      Text(next.today.isEmpty && next.tomorrow != nil ? "TOMORROW" : "NEXT")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tint)
      if let item = next.today.first ?? next.tomorrow {
        TimeText(item: item)
          .font(.title2.weight(.semibold))
          .monospacedDigit()
          .minimumScaleFactor(0.6)
          .lineLimit(1)
        Text(item.title)
          .font(.headline)
          .lineLimit(2)
        if next.today.first != nil, let travel = item.travelText(now: entry.date, time: shortTime) {
          Label(travel, systemImage: "car.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        if next.today.first != nil, !item.isAllDay {
          if item.start > entry.date {
            Text("in \(Text(item.start, style: .relative))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else {
            Text("Now").font(.caption).foregroundStyle(.secondary)
          }
        }
        if next.remainingToday > 1 {
          Text("\(next.remainingToday - 1) more today")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("Nothing else today")
          .font(.headline)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Home Screen medium: the next three items, each opening Today on its day.
struct MediumView: View {
  let entry: NextUpEntry

  var body: some View {
    let next = entry.next
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Next Up")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)
        Spacer()
        if next.remainingToday > next.today.count {
          Text("+\(next.remainingToday - next.today.count) more")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if next.today.isEmpty {
        Text("Nothing else today")
          .font(.headline)
        if let t = next.tomorrow {
          Text("Tomorrow").font(.caption).foregroundStyle(.secondary)
          row(t)
        }
      } else {
        ForEach(next.today) { row($0) }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func row(_ item: WidgetItem) -> some View {
    Link(destination: WidgetLink.url(day: item.start)) {
      HStack(spacing: 8) {
        Image(systemName: item.kind.symbol)
          .font(.caption)
          .foregroundStyle(.tint)
          .frame(width: 16)
        TimeText(item: item)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .frame(minWidth: 52, alignment: .leading)
        Text(item.title)
          .font(.subheadline)
          .lineLimit(1)
        Spacer(minLength: 0)
        if let leaveBy = item.leaveBy, item.start > entry.date {
          Label(
            TravelTime.leaveText(leaveBy: leaveBy, now: entry.date, time: shortTime),
            systemImage: "car.fill"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .layoutPriority(1)
        }
      }
    }
  }
}

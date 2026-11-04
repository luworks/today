#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import SwiftData

  /// One thing on the Calendar tab, whatever it came from: a system event (Apple Calendar, Google, …), an event
  /// Today created itself, or a task planned for a time. The views draw these; they never care where they came from.
  package struct CalEntry: Identifiable {
    package init(
      id: String, source: Source, title: String, location: String = "", start: Date, end: Date,
      isAllDay: Bool, color: Color, calendarTitle: String = "", repeats: Bool = false,
      isBackground: Bool = false, isBirthday: Bool = false, isHoliday: Bool = false
    ) {
      self.id = id
      self.source = source
      self.title = title
      self.location = location
      self.start = start
      self.end = end
      self.isAllDay = isAllDay
      self.color = color
      self.calendarTitle = calendarTitle
      self.repeats = repeats
      self.isBackground = isBackground
      self.isBirthday = isBirthday
      self.isHoliday = isHoliday
    }

    package enum Source {
      case system(String)  // EKEvent identifier
      case local(OneEvent)
      case task(OneTask)
      /// One ring of an alarm: a moment, not a span (start == end).
      case alarm(OneAlarm)
    }

    package let id: String
    package let source: Source
    package let title: String
    package var location = ""
    package let start: Date
    /// Exclusive for all-day entries (the midnight after the last day).
    package let end: Date
    package let isAllDay: Bool
    package let color: Color
    package var calendarTitle = ""
    package var repeats = false
    /// From a subscribed, holiday or Birthdays calendar (see `YearLoad`).
    package var isBackground = false
    package var isBirthday = false
    package var isHoliday = false

    package var isTask: Bool { if case .task = source { true } else { false } }
    package var isAlarm: Bool { if case .alarm = source { true } else { false } }

    package func overlaps(_ day: Date, calendar: Calendar) -> Bool {
      CalendarEntryDates.overlaps(start: start, end: end, day: day, calendar: calendar)
    }

    /// How the entry reads on `day`: all-day rows, or a start/end clipped to that day.
    /// A timed event that spans the whole day (the middle of a multi-day event) reads as all-day.
    package func span(on day: Date, calendar: Calendar) -> (start: Date, end: Date, allDay: Bool) {
      guard let interval = calendar.dateInterval(of: .day, for: day) else {
        return (start, end, isAllDay)
      }
      if isAllDay { return (interval.start, interval.end, true) }
      let s = max(start, interval.start)
      let e = min(end, interval.end)
      return (s, e, start <= interval.start && end >= interval.end)
    }

    package var speech: String {
      if isAlarm {
        return "Alarm \(title) at \(start.formatted(date: .omitted, time: .shortened))"
      }
      if isTask {
        return "\(title), planned \(start.formatted(date: .omitted, time: .shortened))"
      }
      return EventSpeech.label(
        title: title, start: start, end: end, isAllDay: isAllDay, location: location,
        calendar: calendarTitle)
    }
  }

  @MainActor
  package enum CalendarEntries {
    /// Everything overlapping `interval`, merged from the system calendar, Today's own events and timed reminders.
    /// Events hidden in the Calendars list are left out. Pass `alarms` (already empty when "Show alarms in the day" is off)
    /// to add their rings by the same rule as the Today timeline (see `CalendarAlarms`); reminders that ring as alarms stay reminders.
    /// `systemEvents`: the system events already read for `interval` (excluding Today's own), instead of reading them here.
    package static func make(
      in interval: DateInterval, events: [OneEvent], tasks: [OneTask], alarms: [OneAlarm] = [],
      calendarService: any CalendarService, now: Date, calendar: Calendar,
      forYearMarks: Bool = false, systemEvents: [ExternalEvent]? = nil
    ) -> [CalEntry] {
      let sync = calendarService
      var result: [CalEntry] = []

      var mirrors = Set<String>()
      for e in events {
        if e.externalID != nil, sync.usesSystemEventSnapshots { continue }
        if let id = e.externalID { mirrors.insert(id) }
        if sync.isHidden(externalID: e.externalID) { continue }
        let mirror = sync.calendar(forExternalID: e.externalID)
        for start in e.occurrences(in: interval, calendar: calendar) {
          let end =
            forYearMarks
            ? YearEventMarks.localEnd(
              start: start, durationMinutes: e.durationMinutes,
              isAllDay: e.isAllDay, calendar: calendar)
            : start.addingTimeInterval(e.duration)
          result.append(
            CalEntry(
              id: "l\(e.persistentModelID.hashValue)@\(start.timeIntervalSince1970)",
              source: .local(e),
              title: e.title, start: start, end: end, isAllDay: e.isAllDay,
              color: mirror?.color ?? .blue, calendarTitle: mirror?.title ?? e.calendarName,
              repeats: e.repeats != nil,
              isBackground: mirror.map { $0.isBirthday || $0.isHoliday } ?? false,
              isBirthday: mirror?.isBirthday ?? false, isHoliday: mirror?.isHoliday ?? false))
        }
      }

      // Every view preserves EventKit's exclusive all-day end.
      for x in systemEvents ?? sync.events(in: interval, excluding: mirrors) {
        let end = CalendarEntryDates.systemEnd(
          x.end, isAllDay: x.isAllDay,
          forYearMarks: forYearMarks, calendar: calendar)
        result.append(
          CalEntry(
            id: x.id, source: .system(x.eventIdentifier), title: x.title, location: x.location,
            start: x.start, end: end, isAllDay: x.isAllDay, color: x.color,
            calendarTitle: x.calendarTitle,
            repeats: x.repeats, isBackground: x.isBackground, isBirthday: x.isBirthday,
            isHoliday: x.isHoliday))
      }

      for t in tasks where !t.isDone {
        guard let s = t.due, interval.contains(s),
          calendar.dateComponents([.hour, .minute], from: s) != DateComponents(hour: 0, minute: 0)
        else { continue }
        result.append(
          CalEntry(
            id: "t\(t.persistentModelID.hashValue)", source: .task(t), title: t.title, start: s,
            end: s.addingTimeInterval(TimeInterval(t.durationMinutes * 60)), isAllDay: false,
            color: .accentColor, calendarTitle: "Reminders"))
      }

      for ring in CalendarAlarms.occurrences(
        of: alarms.map(\.spec), in: interval, now: now, calendar: calendar)
      {
        let a = alarms[ring.index]
        result.append(
          CalEntry(
            id: "a\(a.persistentModelID.hashValue)@\(ring.date.timeIntervalSince1970)",
            source: .alarm(a),
            title: CalendarAlarms.title(a.label), start: ring.date, end: ring.date,
            isAllDay: false, color: .accentColor, calendarTitle: "Alarms",
            repeats: !a.weekdays.isEmpty))
      }
      return result
    }

    /// The entries on one day, in Apple's order: all-day first, then by start time.
    package static func on(_ day: Date, in entries: [CalEntry], calendar: Calendar) -> [CalEntry] {
      entries
        .filter { $0.overlaps(day, calendar: calendar) }
        .sorted {
          let a = $0.span(on: day, calendar: calendar)
          let b = $1.span(on: day, calendar: calendar)
          if a.allDay != b.allDay { return a.allDay }
          if a.start != b.start { return a.start < b.start }
          return $0.title < $1.title
        }
    }
  }

  /// What the Calendar tab opened: Apple's viewer for system events, our editors for the rest.
  package enum OpenedEntry: Identifiable {
    case system(String)
    /// Apple's editor straight away (the context menu's Edit).
    case editSystem(String)
    case local(OneEvent)
    case task(OneTask)
    /// An alarm opens in the Alarms tab's editor.
    case alarm(OneAlarm)
    /// A new event at a slot picked on the 2 Day grid (long-press), when our editor is used.
    case new(start: Date, end: Date)

    package var id: String {
      switch self {
      case .new(let start, _): "n\(start.timeIntervalSince1970)"
      case .system(let id): "s" + id
      case .editSystem(let id): "e" + id
      case .local(let e): "l\(e.persistentModelID.hashValue)"
      case .task(let t): "t\(t.persistentModelID.hashValue)"
      case .alarm(let a): "a\(a.persistentModelID.hashValue)"
      }
    }

    package init(_ entry: CalEntry) {
      switch entry.source {
      case .system(let id): self = .system(id)
      case .local(let e): self = .local(e)
      case .task(let t): self = .task(t)
      case .alarm(let a): self = .alarm(a)
      }
    }
  }

#endif

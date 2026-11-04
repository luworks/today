#if os(iOS)
  import Foundation
  import One
  import TodayCore

  /// The items an edit sentence ("move the dentist to 4") can name: the next week's events and the open tasks, with short ids.
  /// One place builds them, so the Ask page and the suggestions (which check that a suggested sentence really resolves) agree.
  @MainActor
  enum EditCandidates {
    typealias Result = (items: [EditItem], tasks: [String: OneTask], events: [String: OneEvent])

    static func build(
      events: [OneEvent], tasks: [OneTask], calendarSync: any CalendarService, now: Date,
      calendar cal: Calendar
    ) -> Result {
      let window = DateInterval(
        start: cal.startOfDay(for: now),
        end: cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: now)) ?? now)
      var items: [EditItem] = []
      var taskByID: [String: OneTask] = [:]
      var eventByID: [String: OneEvent] = [:]
      let eventPairs = events.compactMap { e in
        e.occurrences(in: window, calendar: cal).first.map { (e, $0) }
      }
      .sorted { $0.1 < $1.1 }.prefix(8)
      for (i, pair) in eventPairs.enumerated() {
        let id = "e\(i + 1)"
        eventByID[id] = pair.0
        let n = calendarSync.audience(externalID: pair.0.externalID)?.attendees ?? 0
        items.append(
          EditItem(
            id: id, type: "event", title: pair.0.title, start: pair.1,
            minutes: pair.0.durationMinutes, attendees: n))
      }
      let openTasks = tasks.filter { t in
        guard !t.isDone else { return false }
        guard let s = t.due else { return true }
        return window.contains(s)
      }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(12)
      for (i, t) in openTasks.enumerated() {
        let id = "t\(i + 1)"
        taskByID[id] = t
        items.append(
          EditItem(
            id: id, type: "task", title: t.title, start: t.due, minutes: t.durationMinutes,
            attendees: 0))
      }
      return (items, taskByID, eventByID)
    }
  }

#endif

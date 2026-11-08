#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import BackgroundTasks
  import Foundation
  import SwiftData
  import WidgetKit

  /// Feeds the TodayWidgets extension: writes the next few days' items (events, reminders with a time, alarms)
  /// as a small JSON snapshot into the App Group, then asks WidgetKit to reload. The widget never opens SwiftData;
  /// it reads Apple Calendar itself when it can (see `NextItems.merge`), so the snapshot matters most for Today's own items.
  @MainActor
  package final class WidgetFeed {
    private let calendarService: any CalendarService
    private let reminders: any ReminderService
    private let runtime: PlannerRuntime
    private let travel: (String, Date, Bool, TravelPlace?, Date) -> (minutes: Int, leaveBy: Date)?
    private let save: (WidgetSnapshot) -> Bool
    private let reload: () -> Void
    private let enabled: Bool
    private let upNext: UpNextActivity?
    private var disposed = false
    private var scheduleWork: Task<Void, Never>?
    private var refreshWork: Task<Void, Never>?

    package init(
      container: ModelContainer, calendar: any CalendarService, reminders: any ReminderService,
      runtime: PlannerRuntime, enabled: Bool,
      travel: @escaping (String, Date, Bool, TravelPlace?, Date) -> (minutes: Int, leaveBy: Date)?,
      save: @escaping (WidgetSnapshot) -> Bool, reload: @escaping () -> Void,
      upNext: UpNextActivity? = nil
    ) {
      self.container = container
      self.calendarService = calendar
      self.reminders = reminders
      self.runtime = runtime
      self.enabled = enabled
      self.travel = travel
      self.save = save
      self.reload = reload
      self.upNext = upNext
    }
    package func dispose() {
      disposed = true
      scheduleWork?.cancel()
      scheduleWork = nil
      refreshWork?.cancel()
      refreshWork = nil
      upNext?.dispose()
      container = nil
    }

    private var lastWritten: WidgetSnapshot?
    private var container: ModelContainer?

    /// Background refresh: rewrites the snapshot while the app isn't open (at midnight, and whenever iOS allows).
    package nonisolated static let refreshTaskID = "com.luworks.today.widgetRefresh"

    package func update(
      tasks: [OneTask], events: [OneEvent], alarms: [OneAlarm], now: Date, calendar: Calendar
    ) {
      // UI tests run on a throwaway store; keep them from replacing what the widget shows.
      guard enabled, !disposed else { return }
      let items = items(tasks: tasks, events: events, alarms: alarms, now: now, calendar: calendar)
      // Right after launch EventKit is still warming up and system events read as none; writing now would blank them
      // on the widget. The store bumps `CalendarSync.version` when it's ready, which calls this again.
      let sync = calendarService
      guard sync.isReady else { return }
      // Before the unchanged-snapshot return: the card's three-hour window moves even when the items do not.
      upNext?.refresh(items: items, now: now)
      let settings = WidgetSnapshot.CalendarSettings(
        isOn: sync.isOn, hiddenCalendarIDs: sync.hiddenCalendarIDs.sorted())
      if let last = lastWritten, last.items == items, last.calendar == settings { return }
      let snapshot = WidgetSnapshot(generatedAt: now, items: items, calendar: settings)
      guard save(snapshot) else { return }
      lastWritten = snapshot
      reload()
    }

    package func items(
      tasks: [OneTask], events: [OneEvent], alarms: [OneAlarm], now: Date, calendar: Calendar
    ) -> [WidgetItem] {
      let today = calendar.startOfDay(for: now)
      let days = (0..<WidgetSnapshot.days).compactMap {
        calendar.date(byAdding: .day, value: $0, to: today)
      }
      guard let end = calendar.date(byAdding: .day, value: WidgetSnapshot.days, to: today) else {
        return []
      }
      var result: [WidgetItem] = []

      // Apple Calendar events, Today's own events and planned tasks, the way the Calendar tab merges them.
      let entries = CalendarEntries.make(
        in: DateInterval(start: today, end: end), events: events, tasks: tasks,
        calendarService: calendarService, now: now, calendar: calendar)
      for entry in entries {
        switch entry.source {
        case .system(let id):
          let rows = WidgetItem.eventRows(
            id: entry.id, title: entry.title, start: entry.start, end: entry.end,
            isAllDay: entry.isAllDay, externalID: id, days: days, calendar: calendar)
          result += withTravel(
            rows, externalID: id, start: entry.start, isAllDay: entry.isAllDay,
            fallbackAddress: entry.location, now: now)
        case .local(let e):
          let rows = WidgetItem.eventRows(
            id: entry.id, title: entry.title, start: entry.start, end: entry.end,
            isAllDay: entry.isAllDay, externalID: e.externalID, days: days, calendar: calendar)
          result += withTravel(
            rows, externalID: e.externalID, start: entry.start, isAllDay: entry.isAllDay,
            fallbackAddress: "", now: now)
        case .task, .alarm:
          break  // both are added below, one row each; `make` is not given any alarms
        }
      }

      // Reminders with a time on their deadline.
      for t in tasks {
        guard let due = UpNextLive.timedDue(t.due, isDone: t.isDone, calendar: calendar),
          due >= today, due < end
        else { continue }
        result.append(
          WidgetItem(
            id: "d\(t.persistentModelID.hashValue)", title: t.title, start: due, kind: .reminder))
      }

      // Alarms that ring on those days.
      for a in alarms where a.isOn {
        for day in days {
          guard
            let fire = AlarmPlan.fire(
              on: day, hour: a.hour, minute: a.minute, weekdays: a.weekdays, now: now,
              calendar: calendar)
          else { continue }
          let title = a.label.isEmpty ? AlarmPlan.defaultLabel : a.label
          result.append(
            WidgetItem(
              id: "a\(a.persistentModelID.hashValue)#\(Int(day.timeIntervalSince1970))",
              title: title,
              start: fire, kind: .alarm))
        }
      }
      return result.sorted(by: NextItems.ordered)
    }

    /// Adds "Drive 18 min · Leave by" data to the row where the event starts, when Travel time has an estimate.
    /// Reads the cache only (a missing estimate is looked up in the background and rewrites the snapshot when it lands).
    private func withTravel(
      _ rows: [WidgetItem], externalID: String?, start: Date, isAllDay: Bool,
      fallbackAddress: String, now: Date
    ) -> [WidgetItem] {
      guard let externalID else { return rows }
      let place =
        calendarService.place(forExternalID: externalID)
        ?? (fallbackAddress.isEmpty ? nil : TravelPlace(address: fallbackAddress))
      guard let travel = travel(externalID, start, isAllDay, place, now)
      else { return rows }
      return rows.map { row in
        guard row.start == start, !row.isAllDay else { return row }
        var r = row
        r.travelMinutes = travel.minutes
        r.leaveBy = travel.leaveBy
        return r
      }
    }

    // MARK: Background refresh

    /// Must run before launch finishes (`application(_:didFinishLaunchingWithOptions:)`).
    package func registerBackgroundRefresh() {
      guard enabled, !disposed else { return }
      BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: .main) {
        task in
        // BackgroundTasks promises this callback on the explicitly supplied main queue.
        // The ObjC BGTask API carries no actor annotation; no task or context crosses a thread here.
        dispatchPrecondition(condition: .onQueue(.main))
        nonisolated(unsafe) let mainQueueTask = task
        MainActor.assumeIsolated { self.runBackgroundRefresh(mainQueueTask) }
      }
    }

    /// Asks iOS to wake the app in about three hours, and no later than just after midnight (one pending request;
    /// each run books the next one, so this repeats while iOS allows).
    package func scheduleBackgroundRefresh() {
      guard enabled, !disposed else { return }
      scheduleWork?.cancel()
      scheduleWork = Task {
        await submitRefreshRequest(now: runtime.now(), calendar: runtime.calendar)
      }
    }

    private func submitRefreshRequest(now: Date, calendar: Calendar) async {
      guard enabled, !disposed, !Task.isCancelled else { return }
      let midnight =
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        ?? now.addingTimeInterval(86_400)
      let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
      request.earliestBeginDate = min(
        now.addingTimeInterval(3 * 3600), midnight.addingTimeInterval(60))
      try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    @MainActor
    private final class RefreshCompletion {
      private let task: BGTask
      private var finished = false
      init(task: BGTask) { self.task = task }
      func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
      }
    }

    private func runBackgroundRefresh(_ task: BGTask) {
      let completion = RefreshCompletion(task: task)
      guard enabled, !disposed else {
        completion.finish(false)
        return
      }
      let work = Task { @MainActor in
        if enabled { await submitRefreshRequest(now: runtime.now(), calendar: runtime.calendar) }
        guard !disposed, !Task.isCancelled else {
          completion.finish(false)
          return
        }
        await reminders.reconcile()
        guard !disposed, !Task.isCancelled else {
          completion.finish(false)
          return
        }
        calendarService.prepareStore()
        rewriteFromStore()
        await upNext?.settle()
        completion.finish(true)
      }
      refreshWork = work
      task.expirationHandler = {
        work.cancel()
        Task { @MainActor in completion.finish(false) }
      }
    }

    /// Rewrites the snapshot from the data store (no views needed).
    package func rewriteFromStore() {
      guard let context = container?.mainContext else { return }
      let tasks =
        (try? context.fetch(FetchDescriptor<OneTask>(predicate: #Predicate { !$0.isDone }))) ?? []
      let events = (try? context.fetch(FetchDescriptor<OneEvent>())) ?? []
      let alarms = (try? context.fetch(FetchDescriptor<OneAlarm>())) ?? []
      update(
        tasks: tasks, events: events, alarms: alarms, now: runtime.now(), calendar: runtime.calendar
      )
    }
  }
#endif

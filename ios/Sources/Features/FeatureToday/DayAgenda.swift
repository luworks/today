#if os(iOS)
  import One
  import TodayPlannerUI
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import FeatureHealth
  import SwiftUI
  import SwiftData
  import UIKit

  /// One day's view: active events, tasks and alarms stay directly visible in a single timeline,
  /// held in soft Morning / Afternoon / Evening cards (`DayPartRows`).
  /// On today a red "N overdue" line sits above the timeline (tap to show the rows, Tidy to reschedule them all).
  /// A past day also shows what was done on it, rebuilt from Activity (`DayHistory`): reminders completed that day at
  /// their completion time, alarms that were stopped, and events deleted after they happened.
  /// Settle exists only on the device's current day (`SettleGate`): a collapsed Settled disclosure follows its timeline.
  /// The Calendar tab adds the week strip to pick a day.
  package struct DayAgenda: View {
    private let actions: PlannerActions
    private let calendar: any CalendarService
    private let timers: any TimerService
    private let reminders: any ReminderService
    private let ledger: Ledger
    private let travel: any TravelTimeProviding
    @Environment(PlannerPresentation.self) private var presentation
    @Binding var day: Date
    var showsWeekStrip: Bool
    /// Opens the Timer tab (a tap on a running timer's row).
    let openTimer: @MainActor () -> Void
    let openTask: @MainActor (OneTask) -> Void
    let openEvent: @MainActor (OneEvent) -> Void
    let openAlarm: @MainActor (OneAlarm) -> Void
    /// Opens "Tidy overdue" for these reminders (a preview; nothing changes until Apply). Nil hides the button.
    let openTidy: (@MainActor ([OneTask]) -> Void)?

    package init(
      day: Binding<Date>, showsWeekStrip: Bool, openTask: @escaping @MainActor (OneTask) -> Void,
      openEvent: @escaping @MainActor (OneEvent) -> Void,
      openAlarm: @escaping @MainActor (OneAlarm) -> Void,
      openTimer: @escaping @MainActor () -> Void, actions: PlannerActions,
      calendar: any CalendarService, timers: any TimerService, reminders: any ReminderService,
      ledger: Ledger, travel: any TravelTimeProviding, presentation: PlannerPresentation,
      openTidy: (@MainActor ([OneTask]) -> Void)? = nil
    ) {
      self.actions = actions
      self.calendar = calendar
      self.timers = timers
      self.reminders = reminders
      self.ledger = ledger
      self.travel = travel
      _now = State(initialValue: presentation.now)
      _showsAlarms = AppStorage(
        wrappedValue: true, SettingsKey.showAlarms, store: presentation.defaults)
      _jumpsToNow = AppStorage(
        wrappedValue: true, SettingsKey.jumpToNow, store: presentation.defaults)
      _showsHealth = AppStorage(
        wrappedValue: true, SettingsKey.healthSummary, store: presentation.defaults)
      _showsWeather = AppStorage(
        wrappedValue: Preferences.weatherSummary, Preferences.weatherSummaryKey,
        store: presentation.defaults)
      _showsSettle = AppStorage(
        wrappedValue: Preferences.showSettle, Preferences.showSettleKey,
        store: presentation.defaults)
      _showsFreeTime = AppStorage(
        wrappedValue: Preferences.showFreeTime, Preferences.showFreeTimeKey,
        store: presentation.defaults)
      _day = day
      self.showsWeekStrip = showsWeekStrip
      self.openTask = openTask
      self.openEvent = openEvent
      self.openAlarm = openAlarm
      self.openTimer = openTimer
      self.openTidy = openTidy
    }

    @Query(sort: \OneEvent.start) private var events: [OneEvent]
    @Query(sort: \OneTask.createdAt) private var tasks: [OneTask]
    @Query private var alarms: [OneAlarm]
    @AppStorage(SettingsKey.showAlarms) private var showsAlarms = true
    @AppStorage(SettingsKey.jumpToNow) private var jumpsToNow = true
    @AppStorage(SettingsKey.healthSummary) private var showsHealth = true
    @AppStorage(Preferences.weatherSummaryKey) private var showsWeather = Preferences.weatherSummary
    @AppStorage(Preferences.showSettleKey) private var showsSettle = Preferences.showSettle
    @AppStorage(Preferences.showFreeTimeKey) private var showsFreeTime = Preferences.showFreeTime
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(HealthLineModel.self) private var health
    @Environment(WeatherModel.self) private var weather
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }
    @State private var showsAllOverdue = false
    /// Refreshed every minute for the Now line and time-dependent timeline content.
    @State private var now: Date
    /// A repeating system event whose Delete is waiting for "this event or the series?".
    @State private var pendingDelete: CalEntry?
    @State private var timeRequest: TimelineMoveRequest?
    @State private var pendingTime: Date?
    @State private var timeError: String?
    @State private var timeBusy = false
    @State private var dragPreview: TimelineDragPreview?
    @State private var dragRow: AnyView?
    @State private var frozenDayItems: DayItems?
    @State private var swipes = DayPartSwipes()
    @State private var retryTime: Date?
    /// What Activity says happened on `day` (past days only), and the day it was read for.
    @State private var history = DayHistory()
    @State private var historyDay: Date?
    @State private var settledExpanded = false
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?

    package var body: some View {
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          // Any day is one tap away: tomorrow, later this week, or another week with the arrows.
          if !showsWeekStrip {
            WeekStrip(selected: $day, calendar: cal)
              .padding(.horizontal, 8)
              .padding(.bottom, 2)
          }
          list
        }
        .onAppear {
          refreshClock()
          scrollToNow(proxy)
        }
        .onChange(of: day) { _, _ in
          showsAllOverdue = false
          timeRequest = nil
          pendingTime = nil
          dragPreview = nil
          dragRow = nil
          frozenDayItems = nil
          retryTime = nil
          scrollToNow(proxy)
        }
      }
      .onChange(of: tasks.map { "\($0.title)|\($0.due?.timeIntervalSince1970 ?? 0)|\($0.isDone)" })
      { _, _ in loadHistory() }
      .onChange(of: events.map { "\($0.title)|\($0.start.timeIntervalSince1970)" }) { _, _ in
        loadHistory()
      }
      .onChange(of: alarms.map { "\($0.label)|\($0.hour)|\($0.minute)|\($0.isOn)" }) { _, _ in
        loadHistory()
      }
      .overlay { timeAdjustmentPreview.allowsHitTesting(false) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshClock() }
      }
      .onReceive(NotificationCenter.default.publisher(for: ledger.activity.didChange)) { _ in
        loadHistory()
      }
      // Re-read when the day changes, the app comes back (the outbox brings in alarm stops) or a reminder changes.
      .task(
        id:
          "\(cal.startOfDay(for: day).timeIntervalSince1970)|\(scenePhase == .active)|\(tasks.count)|\(calendar.version)|\(events.count)|\(alarms.count)"
      ) {
        loadHistory()
      }
      .alert(
        "Calendar may notify attendees",
        isPresented: Binding(
          get: { pendingTime != nil }, set: { if !$0 { pendingTime = nil } })
      ) {
        Button("Cancel", role: .cancel) { pendingTime = nil }
        Button("Move this occurrence") {
          if let date = pendingTime { submitTime(date) }
          pendingTime = nil
        }
      } message: {
        Text(
          "Updates may be sent to \(timeRequest?.attendees ?? 0) attendees. Undo may send another update."
        )
      }
      .alert(
        "Couldn't change time",
        isPresented: Binding(
          get: { timeError != nil }, set: { if !$0 { timeError = nil } })
      ) {
        if let date = retryTime {
          Button("Try again") {
            timeError = nil
            submitTime(date)
          }
        }
        Button("Close", role: .cancel) { timeError = nil }
      } message: {
        Text(timeError ?? "")
      }
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
      .task(id: [showsHealth, isTodayTab, scenePhase == .active]) {
        // Asks for Health access only the first time the line would show (Today, setting on).
        guard showsHealth, isTodayTab, scenePhase == .active else { return }
        await health.load()
      }
      .task(id: [showsWeather, isTodayTab, scenePhase == .active]) {
        guard !showsWeekStrip else { return }
        weather.update(enabled: showsWeather && isTodayTab && scenePhase == .active)
      }
      .onDisappear {
        if !showsWeekStrip { weather.update(enabled: false) }
      }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
          refreshClock()
          if !Task.isCancelled, !showsWeekStrip, showsWeather, isTodayTab, scenePhase == .active {
            weather.update(enabled: true)
          }
        }
      }
    }

    private var timeAdjustmentPreview: some View {
      GeometryReader { geometry in
        if let preview = dragPreview {
          let width = min(300.0, geometry.size.width - 24)
          let origin = geometry.frame(in: .global).origin
          let x = min(
            geometry.size.width - width / 2 - 12,
            max(width / 2 + 12, preview.finger.x - origin.x - width / 2 - 24))
          let y = min(
            max(160, geometry.size.height - 160),
            max(160, preview.finger.y - origin.y - 100))
          VStack(alignment: .leading, spacing: 8) {
            if let row = dragRow { row.accessibilityHidden(true) }
            TimelineDragRuler(preview: preview)
          }.padding(12).frame(width: width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: reduceMotion ? 0 : 5)
            .position(x: x, y: y)
            .allowsHitTesting(false)
        }
      }
    }

    /// Reuse the existing clock refresh and foreground boundary; keep explicitly browsed days.
    private func refreshClock() {
      let next = presentation.now
      if !showsWeekStrip {
        day = presentation.runtime.refreshedTodayDay(day, previousNow: now, now: next)
      }
      now = next
    }

    /// Open on what is happening now: the day's schedule scrolls to the "now" line.
    private func scrollToNow(_ proxy: ScrollViewProxy) {
      guard cal.isDate(day, inSameDayAs: now), jumpsToNow else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo("now-line", anchor: .center) }
      }
    }

    private var isPastDay: Bool { cal.startOfDay(for: day) < cal.startOfDay(for: now) }

    /// Reads the day's history from the Activity store: indexed, paged day-range queries (`DayHistory.load`). Read-only.
    private func loadHistory() {
      observePlans()
      let start = cal.startOfDay(for: day)
      guard isPastDay, let store = ledger.activity.store else {
        history = DayHistory()
        historyDay = nil
        return
      }
      ledger.activity.recorder.flush()
      history =
        (try? DayHistory.load(
          from: store, day: start, calendar: cal, shownLive: [], reopened: [],
          key: Ledger.comparisonKey)) ?? DayHistory()
      historyDay = start
    }

    /// Capture only occurrences actually loaded for the viewed date. No claim of daily background coverage.
    private func observePlans() {
      let local = events.filter { $0.externalID == nil || !calendar.usesSystemEventSnapshots }
      func record(
        _ title: String, _ kind: String, _ ref: String?, _ start: Date,
        _ end: Date? = nil, _ allDay: Bool = false
      ) {
        guard let ref else { return }
        ledger.activity.observePlan(
          title: title, kind: kind, reference: Ledger.comparisonKey(ref),
          start: start, end: end, allDay: allDay, calendar: cal)
      }
      for event in local {
        for start in event.occurs(on: day, calendar: cal) {
          record(
            event.title, "event", Ledger.ref(event.persistentModelID), start,
            start.addingTimeInterval(event.duration), event.isAllDay)
        }
      }
      for event in calendar.events(on: day, excluding: Set(local.compactMap(\.externalID))) {
        // Resolve the existing normalized source identity; a transient EventKit ID is not identity.
        if case .available(let identity) = calendar.cachedFocusIdentity(
          externalID: event.eventIdentifier, occurrence: event.start),
          let bytes = try? JSONEncoder().encode(identity),
          let ref = String(data: bytes, encoding: .utf8)
        {
          record(event.title, "event", ref, event.start, event.end, event.isAllDay)
        }
      }
      for task in tasks where !task.isDone {
        if let due = task.due, cal.isDate(due, inSameDayAs: day) {
          record(
            task.title, "task", Ledger.ref(task.persistentModelID), due, nil,
            !plannerDueHasTime(task, calendar: presentation.calendar))
        }
      }
      for ring in CalendarAlarms.occurrences(
        of: alarms.map(\.spec), on: day, now: now, calendar: cal)
      {
        let alarm = alarms[ring.index]
        record(alarm.label, "alarm", alarm.alarmKitID?.uuidString, ring.date)
      }
    }

    /// The Today tab on today (not the Calendar tab, not another day).
    private var isTodayTab: Bool { !showsWeekStrip && cal.isDate(day, inSameDayAs: now) }

    private var list: some View {
      let items = frozenDayItems ?? items(on: day, now: now)
      return List {
        // Running timers: a live countdown at the top of today.
        if isTodayTab { TodayTimerRows(controller: timers, open: openTimer) }
        if isTodayTab, showsHealth, let line = health.line {
          TodayHealthLine(line: line)
        }
        if isTodayTab, showsWeather, weather.isAvailable {
          if let snapshot = weather.snapshot {
            TodayWeatherLine(snapshot: snapshot)
          } else if weather.state == .loading {
            Text("Loading weather…")
              .font(.footnote).foregroundStyle(.secondary)
              .accessibilityIdentifier("weather.loading")
              .listRowSeparator(.hidden)
          } else if weather.state == .locationDenied || weather.state == .unavailable {
            Button {
              if weather.state == .locationDenied,
                let url = URL(string: UIApplication.openSettingsURLString)
              {
                UIApplication.shared.open(url)
              } else {
                weather.update(enabled: true, force: true)
              }
            } label: {
              Label(
                weather.state == .locationDenied
                  ? "Allow location for weather" : "Weather unavailable · Try again",
                systemImage: "cloud"
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("weather.retry")
            .listRowSeparator(.hidden)
          }
        }
        if settlesHere, let error = actions.focus.errorMessage {
          Text(error).font(.footnote).foregroundStyle(.secondary)
        }
        // Overdue first: never moved silently, and one tap from a new date.
        if isTodayTab, !overdue.isEmpty { overdueSection }
        if !items.allDay.isEmpty || !items.externalAllDay.isEmpty {
          Section {
            if !showsWeekStrip {
              // An inline caption avoids the plain List section header's reserved vertical space.
              AgendaHeader(title: "All day", isInline: true)
                .accessibilityAddTraits(.isHeader)
                .listRowSeparator(.hidden)
            }
            ForEach(items.allDay) {
              EventRow(
                event: $0, pendingDelete: $pendingDelete, open: openEvent, calendar: calendar,
                travel: travel,
                attention: attention(
                  target($0, start: $0.occurs(on: day, calendar: cal).first ?? $0.start),
                  canDelete: canDelete($0))
              )
            }
            ForEach(items.externalAllDay) {
              ExternalEventRow(
                event: $0, pendingDelete: $pendingDelete, calendar: calendar, travel: travel,
                attention: attention(target($0), canDelete: canDelete($0))
              )
            }
          } header: {
            if showsWeekStrip { AgendaHeader(title: "All day") }
          }
        }
        // The Today tab's week strip names its day; the timeline needs no label of its own.
        if showsWeekStrip {
          Section {
            timelineContent(items)
          } header: {
            AgendaHeader(
              title: day.plannerFormatted(
                .dateTime.month().day().weekday(.wide), runtime: presentation.runtime))
          }
        } else {
          Section { timelineContent(items) }
        }
        if settlesHere, showsSettle { settledSection }
      }
      .listStyle(.plain)
      .animation(reduceMotion ? nil : .snappy, value: items.timeline.map(\.start))
      // Interactive rows own their 44pt targets. Today captions and gaps use their natural text height.
      .environment(\.defaultMinListRowHeight, showsWeekStrip ? 24 : 0)
      .listSectionSpacing(showsWeekStrip ? 6 : 0)
      .scrollContentBackground(.hidden)
      .background(alignment: .topLeading) { DayPartSwipeLayer(swipes: swipes) }
      .entryDeleteDialog($pendingDelete)
    }

    @ViewBuilder
    private func timelineContent(_ items: DayItems) -> some View {
      if isPastDay {
        if historyDay == cal.startOfDay(for: day) {
          let untimed = history.facts.filter { $0.isPrimary && $0.isUntimedPlan }
          let allDay = untimed.filter { $0.event.subjectKind == "event" }
          if !allDay.isEmpty {
            AgendaHeader(title: "All day", isInline: !showsWeekStrip)
            ForEach(allDay) { fact in HistoricalFactRow(fact: fact, todayStyle: !showsWeekStrip) }
          }
          DayPartRows(
            rows: DayPart.rows(
              history.facts.filter { $0.isPrimary && !$0.isUntimedPlan }, day: day, calendar: cal,
              start: \.at, isPlanned: { _ in true }), swipes: swipes
          ) { fact in
            HistoricalFactRow(fact: fact, todayStyle: !showsWeekStrip)
          }
          let anytime = untimed.filter { $0.event.subjectKind != "event" }
          if !anytime.isEmpty {
            AnytimeLabel(title: "Anytime")
            ForEach(anytime) { fact in HistoricalFactRow(fact: fact, todayStyle: !showsWeekStrip) }
          }
          let changes = history.facts.filter { !$0.isPrimary }
          if !changes.isEmpty {
            DisclosureGroup("Changes (\(changes.count))") {
              ForEach(changes) { fact in HistoricalFactRow(fact: fact, todayStyle: !showsWeekStrip)
              }
            }
          }
          if history.facts.isEmpty {
            Text("No recorded history").foregroundStyle(.secondary)
          }
        }
      }
      if !isPastDay, items.timeline.isEmpty, items.anytime.isEmpty {
        Text("Nothing planned").foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
      }
      DayPartRows(
        rows: DayPart.rows(
          items.timeline, day: day, calendar: cal, start: \.start, isPlanned: \.isPlanned),
        swipes: swipes
      ) { item in
        dayItemRow(item, items: items)
      }
      if !items.anytime.isEmpty {
        AnytimeLabel(title: cal.isDate(day, inSameDayAs: now) ? "Anytime today" : "Anytime")
        ForEach(items.anytime) { task in
          TaskRow(
            task: task, compact: true, agendaDay: day, onDelete: { requestDelete(task) },
            open: openTask, attention: attention(target(task), canDelete: canDelete(task))
          )
        }
      }
    }

    /// A timeline row, with its time handle where it can move.
    @ViewBuilder
    private func dayItemRow(_ item: TimelineItem, items: DayItems) -> some View {
      if !isPastDay, let timing = dragTiming(item) {
        timelineRow(item, on: day)
          .modifier(
            TimelineTimeAdjustment(
              timing: timing,
              begin: {
                guard !timeBusy else { return false }
                prepareTime(item, timing: timing)
                guard timeRequest != nil else { return false }
                frozenDayItems = items
                dragRow = AnyView(timelineRow(item, on: day))
                return true
              },
              commit: { date in
                guard timeRequest != nil else { return }
                if (timeRequest?.attendees ?? 0) > 0 {
                  pendingTime = date
                } else {
                  submitTime(date)
                }
              }, edit: { editTime(item) },
              previewChanged: { preview in
                dragPreview = preview
                if preview == nil {
                  dragRow = nil
                  frozenDayItems = nil
                }
              },
              overlaps: { date in
                items.timeline.contains { other in
                  guard other.id != item.id else { return false }
                  let length: TimeInterval
                  switch other {
                  case .event(let event, _): length = event.duration
                  case .external(let event): length = event.end.timeIntervalSince(event.start)
                  case .due(let task):
                    guard !task.isDone else { return false }
                    length = 0
                  case .alarm(_, _, let stopped):
                    guard stopped == nil else { return false }
                    length = 0
                  default: return false
                  }
                  if timing.duration == 0 {
                    return length == 0
                      ? date == other.start
                      : date >= other.start && date < other.start.addingTimeInterval(length)
                  }
                  if length == 0 {
                    return other.start >= date
                      && other.start < date.addingTimeInterval(timing.duration)
                  }
                  return date < other.start.addingTimeInterval(length)
                    && date.addingTimeInterval(timing.duration) > other.start
                }
              })
          )
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
          .listRowSeparator(.hidden)
          .disabled(timeBusy)
      } else {
        timelineRow(item, on: day)
      }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem, on rowDay: Date) -> some View {
      switch item {
      case .event(let event, let start):
        EventRow(
          event: event, start: start, pendingDelete: $pendingDelete, open: openEvent,
          calendar: calendar, travel: travel,
          attention: attention(
            target(event, start: start), canDelete: canDelete(event), on: rowDay)
        )
      case .external(let e):
        ExternalEventRow(
          event: e, pendingDelete: $pendingDelete, calendar: calendar, travel: travel,
          attention: attention(target(e), canDelete: canDelete(e), on: rowDay)
        )
      case .due(let task):
        TaskRow(
          task: task, showsTime: true, time: task.due, compact: true, agendaDay: rowDay,
          onDelete: { requestDelete(task) }, open: openTask,
          attention: attention(target(task), canDelete: canDelete(task), on: rowDay)
        )
      case .alarm(let alarm, let date, let stoppedAt):
        AlarmMarkRow(
          alarm: alarm, date: date, open: openAlarm,
          attention: attention(
            target(alarm, fireDate: date), canDelete: true, on: rowDay),
          onDelete: showsWeekStrip
            ? nil : { _ = actions.delete(alarm, context: context, toast: toast) },
          stoppedAt: stoppedAt)
      case .done(let task, let doneAt):
        TaskRow(
          task: task, showsTime: true, time: doneAt, compact: true, agendaDay: rowDay,
          onDelete: { requestDelete(task) }, open: openTask,
          // A past day: never Settle (`SettleGate`), so this only carries whether Delete is allowed.
          attention: attention(target(task), canDelete: canDelete(task), on: rowDay)
        )
      case .completed(let c):
        PastDayRow(
          time: c.at, title: c.title, detail: "Completed", mark: .completed,
          todayStyle: !showsWeekStrip)
      case .stoppedAlarm(let stop):
        PastDayRow(
          time: stop.at, title: stop.title, detail: "Alarm stopped", mark: .stopped,
          todayStyle: !showsWeekStrip)
      case .deletedEvent(let e):
        PastDayRow(
          time: e.start, title: e.title,
          detail: DurationLabel.text(minutes: max(1, Int(e.end.timeIntervalSince(e.start) / 60)))
            + " · Deleted later",
          mark: .deletedEvent, todayStyle: !showsWeekStrip)
      case .gap(let free): FreeRow(free: free)
      case .nowMarker(let date): NowRow(date: date).id("now-line")
      }
    }

    private func dragTiming(_ item: TimelineItem) -> TimelineDragTime? {
      let duration: TimeInterval
      switch item {
      case .event(let event, let start):
        duration = TimeInterval(event.durationMinutes * 60)
        guard start.addingTimeInterval(duration) > now else { return nil }
      case .external(let event):
        guard event.end > now else { return nil }
        duration = event.end.timeIntervalSince(event.start)
      case .due: duration = 0
      case .alarm(_, _, let stopped):
        guard stopped == nil else { return nil }
        duration = 0
      default: return nil
      }
      let minimum: Date?
      var maximum: Date?
      if case .due = item {
        // Midnight is the existing date-only sentinel, not a representable timed deadline.
        minimum = cal.startOfDay(for: day).addingTimeInterval(60)
      } else if case .alarm(let alarm, _, _) = item, alarm.weekdays.isEmpty {
        // The existing AlarmKit relative model can represent only the next matching clock time.
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        minimum = minute.addingTimeInterval(60)
        maximum = cal.date(byAdding: .day, value: 1, to: minute)
      } else {
        minimum = nil
      }
      return TimelineDragTime(
        original: item.start, day: day, duration: duration,
        calendar: cal, minimumStart: minimum, maximumStart: maximum)
    }

    private func editTime(_ item: TimelineItem) {
      switch item {
      case .due(let task): openTask(task)
      case .event(let event, _): openEvent(event)
      case .alarm(let alarm, _, _): openAlarm(alarm)
      case .external(let event):
        (calendar as? any NativeCalendarService)?.edit(
          identifier: event.eventIdentifier, start: event.start, end: event.end, onComplete: nil)
      default: break
      }
    }

    private func prepareTime(_ item: TimelineItem, timing: TimelineDragTime) {
      timeRequest = nil
      retryTime = nil
      guard timing.duration == 0 || timing.original <= timing.latest else {
        timeError = "This event continues into another day. Open its editor to change its time."
        return
      }
      do {
        switch item {
        case .due(let task):
          guard !task.isDone else { throw CocoaError(.userCancelled) }
          let snapshot = Ledger.snapshot(of: task)
          let apply: (Date) throws -> AttachedReminderActions.Receipt
          if snapshot.repeatRule != nil {
            let move = try ReminderOccurrenceMove(
              series: task, expected: snapshot, context: context, reminders: reminders,
              ledger: ledger, runtime: presentation.runtime)
            apply = { try move.apply(to: $0) }
          } else {
            // A native repeat rule may be richer than the local model. Reject only this drag path.
            _ = try reminders.prepareOccurrenceMove(task, expected: snapshot)
            apply = { date in
              try actions.applyAttachedReminder(
                .move(date), task: task, expected: snapshot, context: context, actor: .you,
                channel: .app)
            }
          }
          timeRequest = TimelineMoveRequest(timing: timing) { date in
            let receipt = try apply(date)
            @MainActor func restore() {
              do { try receipt.undo() } catch {
                toast?.show(
                  "Couldn't restore reminder. " + error.localizedDescription, undo: restore)
              }
            }
            return restore
          }
        case .alarm(let alarm, _, _):
          guard alarm.weekdays.isEmpty else {
            timeError =
              "Repeating alarms use a weekly AlarmKit schedule. A single ring cannot be moved without changing later rings. Open the alarm for an explicit repeat edit."
            return
          }
          // Construct at release only after comparing the captured settings.
          let before = alarm.activitySnapshot
          let created = alarm.createdAt
          timeRequest = TimelineMoveRequest(timing: timing) { date in
            guard alarm.activitySnapshot == before, alarm.createdAt == created else {
              throw AttachedAlarmChange.Failure.changed
            }
            let change = try AttachedAlarmChange(alarm: alarm, edit: .move(date))
            let entry = try await actions.applyAttachedAlarm(
              change, context: context, actor: .you, channel: .app)
            @MainActor func restore() {
              Task { @MainActor in
                if let error = await actions.undo(entry, context: context) {
                  toast?.show("Couldn't restore alarm. " + error, undo: restore)
                }
              }
            }
            return restore
          }
        case .event(let event, let occurrence):
          guard let id = event.externalID else {
            prepareLocalTime(event, timing: timing)
            return
          }
          try prepareCalendarTime(id: id, occurrence: occurrence, timing: timing)
        case .external(let event):
          try prepareCalendarTime(
            id: event.eventIdentifier, occurrence: event.start, timing: timing)
        default: break
        }
      } catch CalendarMoveError.readOnly {
        timeError = "This calendar is read-only. Its events cannot be moved."
      } catch {
        timeError = "This item cannot be moved safely: " + error.localizedDescription
      }
    }

    private func prepareLocalTime(_ event: OneEvent, timing: TimelineDragTime) {
      let before = localEventSnapshot(event)
      timeRequest = TimelineMoveRequest(timing: timing) { date in
        guard !event.isDeleted, event.modelContext === context,
          localEventSnapshot(event) == before,
          try savedLocalEventMatches(event, snapshot: before)
        else {
          throw NSError(
            domain: "TimelineMove", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "This event changed since the preview."])
        }
        let original = event.start
        let overrides = event.occurrenceOverrides
        if event.repeatRule != nil {
          event.occurrenceOverrides = OccurrenceTimes.moving(
            overrides, from: timing.original, to: date)
        } else {
          event.start = date
        }
        do { try context.save() } catch {
          event.start = original
          event.occurrenceOverrides = overrides
          throw error
        }
        let after = localEventSnapshot(event)
        let entry = ledger.record(
          .moved, kind: "event", title: event.title,
          before: ledger.timeLabel(timing.original), after: ledger.timeLabel(date),
          beforeDate: timing.original, afterDate: date, actor: .you, channel: .app,
          approval: .userMade, context: context)
        return {
          guard !event.isDeleted, event.modelContext === context,
            localEventSnapshot(event) == after,
            (try? savedLocalEventMatches(event, snapshot: after)) == true
          else {
            toast?.showNotice("Changed since. Open the event to check its time.")
            return
          }
          let afterOverrides = event.occurrenceOverrides
          event.start = original
          event.occurrenceOverrides = overrides
          do {
            try context.save()
            ledger.recordUndo(of: entry, channel: .app, context: context)
          } catch {
            event.start = event.repeatRule == nil ? date : original
            event.occurrenceOverrides = afterOverrides
            toast?.showNotice(error.localizedDescription)
          }
        }
      }
    }

    private func savedLocalEventMatches(_ event: OneEvent, snapshot: [String]) throws -> Bool {
      let reader = ModelContext(context.container)
      let saved = try reader.fetch(FetchDescriptor<OneEvent>()).first {
        $0.persistentModelID == event.persistentModelID
      }
      return saved.map { localEventSnapshot($0) == snapshot } ?? false
    }

    private func localEventSnapshot(_ event: OneEvent) -> [String] {
      [
        event.title, event.note, event.location ?? "", event.url ?? "",
        String(describing: event.busy),
        String(event.start.timeIntervalSince1970), String(event.durationMinutes),
        event.calendarName,
        String(describing: event.reminderOffsetMinutes), String(event.isAllDay),
        String(event.ringsAsAlarm),
        event.externalID ?? "", event.repeatRule ?? "",
        String(describing: event.occurrenceOverrides),
      ]
    }

    private func prepareCalendarTime(id: String, occurrence: Date, timing: TimelineDragTime) throws
    {
      let snapshot = try calendar.moveSnapshot(externalID: id, occurrence: occurrence)
      timeRequest = TimelineMoveRequest(timing: timing, attendees: snapshot.audience.attendeeCount)
      { date in
        var lastUndoReport: String?
        let result = ToolRegistry.apply(
          SystemMoveProposal(expected: snapshot, start: date), context: context,
          calendar: calendar, ledger: ledger, actor: .you, channel: .app,
          report: { message in
            lastUndoReport = message
            toast?.showNotice(message)
          })
        guard let undo = result.result.undo, result.moved != nil else {
          throw NSError(
            domain: "TimelineMove", code: 1,
            userInfo: [NSLocalizedDescriptionKey: result.result.replies.joined(separator: " ")])
        }
        @MainActor func restore() {
          undo.run()
          if undo.canRetry?() == true {
            toast?.show(lastUndoReport ?? "Couldn't restore event. Try Undo again.", undo: restore)
          }
        }
        return restore
      }
    }

    private func submitTime(_ date: Date) {
      guard !timeBusy, let request = timeRequest else { return }
      timeBusy = true
      retryTime = date
      Task { @MainActor in
        defer { timeBusy = false }
        do {
          try await request.apply(date, toast: toast)
          timeRequest = nil
          retryTime = nil
        } catch { timeError = error.localizedDescription }
      }
    }

    // MARK: One day's items

    private func items(on day: Date, now: Date) -> DayItems {
      if isPastDay {
        // Past rows are reconstructed from retained observations, never from mutable source models.
        return DayItems(allDay: [], externalAllDay: [], timeline: [], anytime: [])
      }

      let local = events.filter { $0.externalID == nil || !calendar.usesSystemEventSnapshots }
      let external = calendar.events(on: day, excluding: Set(local.compactMap(\.externalID)))
      var timeline: [TimelineItem] = []
      var busy: [DateInterval] = []
      for e in local where !e.isAllDay {
        for start in e.occurs(on: day, calendar: cal) {
          timeline.append(.event(e, start))
          busy.append(DateInterval(start: start, duration: TimeInterval(e.durationMinutes * 60)))
        }
      }
      for e in external where !e.isAllDay {
        timeline.append(.external(e))
        busy.append(DateInterval(start: e.start, end: max(e.start, e.end)))
      }
      // Today shows overdue reminders in its overdue line; a browsed past day keeps its own timeline.
      // A completed task leaves the day (Undo in the toast brings it back).
      let open = tasks.filter {
        !$0.isDone
          && (!cal.isDate(day, inSameDayAs: now) || !plannerIsOverdue($0, now: now, calendar: cal))
      }
      var anytime: [OneTask] = []
      for task in open {
        guard let due = task.due, cal.isDate(due, inSameDayAs: day) else { continue }
        if plannerDueHasTime(task, calendar: presentation.calendar) {
          timeline.append(.due(task))
          busy.append(DateInterval(start: due, duration: TimeInterval(task.durationMinutes * 60)))
        } else {
          anytime.append(task)
        }
      }
      // Reminders with no time stay under "Anytime", flagged first.
      anytime.sort { ($0.flagged ? 0 : 1, $0.createdAt) < ($1.flagged ? 0 : 1, $1.createdAt) }
      // What is still free, as quiet "Free 1 h 30 min" rows.
      if showsFreeTime {
        timeline += DaySchedule.freeGaps(busy: busy, day: day, now: now, calendar: cal).map(
          TimelineItem.gap)
      }
      let rings =
        showsAlarms
        ? CalendarAlarms.occurrences(of: alarms.map(\.spec), on: day, now: now, calendar: cal)
        : []
      // A past day: what Activity says was done on it. Today and later days are unchanged.
      let past = pastItems(rings: rings)
      timeline += rings.indices.map { i in
        TimelineItem.alarm(alarms[rings[i].index], rings[i].date, past.stoppedAt[i])
      }
      timeline += past.items
      if cal.isDate(day, inSameDayAs: now), !timeline.isEmpty {
        timeline.append(.nowMarker(now))
      }
      return DayItems(
        allDay: local.filter {
          $0.isAllDay && !$0.occurs(on: day, calendar: cal).isEmpty
            && !isHidden(
              target($0, start: $0.occurs(on: day, calendar: cal).first ?? $0.start), on: day)
        },
        externalAllDay: external.filter { $0.isAllDay && !isHidden(target($0), on: day) },
        // At the same minute the Now line comes first, so free time from now sits under it.
        timeline: timeline.filter { !isHidden($0, on: day) }.sorted {
          ($0.start, $0.isNow ? 0 : 1) < ($1.start, $1.isNow ? 0 : 1)
        },
        anytime: anytime.filter { !isHidden(target($0), on: day) })
    }

    /// On a past day: reminders completed that day (the live row when Today still has the reminder done, else the Activity
    /// row), which rings were stopped, stops of alarms no longer scheduled, and events deleted after they had started.
    private func pastItems(rings: [AlarmOccurrence]) -> (
      items: [TimelineItem], stoppedAt: [Int: Date]
    ) {
      guard isPastDay else { return ([], [:]) }
      var items: [TimelineItem] = []
      var shownLive = Set<String>()
      var reopened = Set<String>()
      let refs = Set(history.completions.compactMap(\.ref))
      for task in tasks {
        let doneToday = task.isDone && task.doneAt.map { cal.isDate($0, inSameDayAs: day) } == true
        if doneToday, let doneAt = task.doneAt { items.append(.done(task, doneAt)) }
        guard !refs.isEmpty, doneToday || (!task.isDone && task.repeats == nil),
          let key = Ledger.ref(task.persistentModelID).map(Ledger.comparisonKey), refs.contains(key)
        else { continue }
        if doneToday { shownLive.insert(key) } else { reopened.insert(key) }
      }
      // `history` may still hold the previous day for a moment after the day changes.
      guard historyDay == cal.startOfDay(for: day) else { return (items, [:]) }
      for c in history.completions {
        guard let ref = c.ref else {
          items.append(.completed(c))
          continue
        }
        if !shownLive.contains(ref), !reopened.contains(ref) { items.append(.completed(c)) }
      }
      var stoppedAt: [Int: Date] = [:]
      if showsAlarms {
        let match = DayHistory.matchStops(
          rings: rings.map { (alarms[$0.index].alarmKitID?.uuidString, $0.date) },
          stops: history.alarmStops)
        stoppedAt = match.stopped
        items += match.unmatched.map(TimelineItem.stoppedAlarm)
      }
      items += history.deletedEvents.map(TimelineItem.deletedEvent)
      return (items, stoppedAt)
    }

    /// Deleting a reminder never asks: the Undo toast is the safety net.
    private func requestDelete(_ task: OneTask) { deleteConfirmed(task) }

    private func deleteConfirmed(_ task: OneTask) {
      do {
        try actions.deleteConfirmed(task, context: context, toast: toast)
      } catch {
        toast?.showNotice(
          "Couldn't delete this reminder. " + error.localizedDescription + " Try again.")
      }
    }

    // MARK: Local attention overlay

    private func target(_ task: OneTask) -> FocusTarget {
      let ref = TodayFocus.reference(task.persistentModelID)
      return FocusTarget(
        identity: actions.focus.identity(
          resolution: reminders.focusIdentity(task), localReference: ref, kind: "reminder",
          occurrence: task.repeats == nil ? nil : task.due),
        reference: ref, title: task.title, subject: AskSubject(task: task))
    }

    private func target(_ event: OneEvent, start: Date) -> FocusTarget {
      let ref = TodayFocus.reference(event.persistentModelID)
      return FocusTarget(
        identity: actions.focus.identity(
          resolution: calendar.cachedFocusIdentity(externalID: event.externalID, occurrence: start),
          localReference: ref, kind: "event", occurrence: event.repeats == nil ? nil : start),
        reference: ref, title: event.title, subject: AskSubject(event: event, start: start))
    }

    private func target(_ event: ExternalEvent) -> FocusTarget {
      let ref = "eventkit:" + event.eventIdentifier
      return FocusTarget(
        identity: actions.focus.identity(
          resolution: calendar.cachedFocusIdentity(
            externalID: event.eventIdentifier, occurrence: event.start),
          localReference: ref, kind: "event", occurrence: event.repeats ? event.start : nil),
        reference: ref, title: event.title, subject: AskSubject(event: event))
    }

    private func target(_ alarm: OneAlarm, fireDate: Date) -> FocusTarget {
      let ref = TodayFocus.reference(alarm.persistentModelID)
      return FocusTarget(
        identity: actions.focus.identity(
          resolution: .localOnly, localReference: ref, kind: "alarm", occurrence: fireDate),
        reference: ref, title: alarm.label.isEmpty ? "Alarm" : alarm.label,
        subject: AskSubject(alarm: alarm))
    }

    /// Settle lives on the Today tab's current day only (`SettleGate`); past and future days never offer or apply it.
    private func settles(on rowDay: Date? = nil) -> Bool {
      !showsWeekStrip && SettleGate.applies(to: day, now: now, calendar: cal)
        && SettleGate.applies(to: rowDay ?? day, now: now, calendar: cal)
    }

    private var settlesHere: Bool { settles() }

    /// `target` is built only when the row can be settled; `canDelete` comes straight from the row's own model.
    private func attention(
      _ target: @autoclosure () -> FocusTarget, canDelete: Bool, on rowDay: Date? = nil
    ) -> TodayRowAttention? {
      guard !showsWeekStrip else { return nil }
      var settle: (() -> Void)?
      if showsSettle, settles(on: rowDay) {
        let target = target()
        if target.identity != nil {
          settle = { _ = changeFocus(.settled, target: target, on: rowDay ?? day) }
        }
      }
      return TodayRowAttention(settle: settle, canDelete: canDelete)
    }

    /// Whether the source accepts a delete (a read-only calendar, or a reminder whose source can't be reached, does not).
    private func canDelete(_ task: OneTask) -> Bool {
      switch reminders.focusIdentity(task) {
      case .available, .localOnly: true
      default: false
      }
    }

    private func canDelete(_ event: OneEvent) -> Bool {
      event.externalID == nil || calendar.cachedCanDelete(externalID: event.externalID)
    }

    private func canDelete(_ event: ExternalEvent) -> Bool {
      calendar.cachedCanDelete(externalID: event.eventIdentifier)
    }

    /// Settled items leave today's timeline. A past or future day shows every row, whatever was settled on it.
    /// (An older Snooze record no longer hides anything.)
    private func isHidden(_ target: @autoclosure () -> FocusTarget, on rowDay: Date? = nil) -> Bool
    {
      settles(on: rowDay) && !actions.focus.records.isEmpty
        && actions.focus.state(for: target().identity, now: now, on: rowDay ?? day) == .settled
    }

    private func isHidden(_ item: TimelineItem, on rowDay: Date) -> Bool {
      switch item {
      case .event(let event, let start): isHidden(target(event, start: start), on: rowDay)
      case .external(let event): isHidden(target(event), on: rowDay)
      case .due(let task): isHidden(target(task), on: rowDay)
      case .alarm(let alarm, let date, _): isHidden(target(alarm, fireDate: date), on: rowDay)
      case .done, .completed, .stoppedAlarm, .deletedEvent, .gap, .nowMarker: false
      }
    }

    @discardableResult
    private func changeFocus(_ state: TodayFocusState?, target: FocusTarget, on rowDay: Date? = nil)
      -> Bool
    {
      withAnimation(reduceMotion ? nil : .snappy) {
        actions.focus.change(
          state, identity: target.identity, localReference: target.reference,
          title: target.title, context: context, toast: toast, on: rowDay ?? day)
      }
    }

    private func focusHeader(
      _ title: String, count: Int, id: String, expanded: Binding<Bool>
    )
      -> some View
    {
      Button {
        withAnimation(reduceMotion ? nil : .snappy) { expanded.wrappedValue.toggle() }
      } label: {
        HStack {
          Text("\(title) (\(count))").font(AgendaRowStyle.disclosure.weight(.medium))
          Rectangle().fill(.quaternary).frame(height: 1)
          Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      .accessibilityIdentifier("focus." + id)
      .accessibilityLabel("\(title) (\(count))")
      .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
      .accessibilityHint("Changes visibility for this day in Today only")
    }

    private var overdueRows: some View {
      ForEach(overdue) { task in
        TaskRow(
          task: task, compact: true, agendaDay: day, onDelete: { requestDelete(task) },
          open: openTask, attention: attention(target(task), canDelete: canDelete(task))
        )
      }
    }

    @ViewBuilder private var overdueSection: some View {
      HStack(spacing: 12) {
        Button {
          withAnimation(reduceMotion ? nil : .snappy) { showsAllOverdue.toggle() }
        } label: {
          HStack(spacing: 6) {
            Text("\(overdue.count) overdue").font(.subheadline.weight(.semibold))
              .foregroundStyle(.red)
            Image(systemName: showsAllOverdue ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
          }
          .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("today.overdueShortcut")
        .accessibilityLabel("\(overdue.count) overdue")
        .accessibilityValue(showsAllOverdue ? "Expanded" : "Collapsed")
        if let openTidy {
          Button("Tidy") { openTidy(overdue) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.red)
            .accessibilityIdentifier("today.tidyOverdue")
            .accessibilityHint(
              "Suggests a new date for each overdue reminder. Nothing changes until Apply.")
        }
      }
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      if showsAllOverdue { overdueRows }
    }

    private var settledRecords: [FocusRecord] {
      actions.focus.records.filter {
        cal.isDate($0.agendaDay(calendar: cal), inSameDayAs: day)
          && actions.focus.state(for: $0.identity, now: now, on: day) == .settled
      }
    }

    @ViewBuilder private var settledSection: some View {
      let records = settledRecords
      focusHeader("Settled", count: records.count, id: "settled", expanded: $settledExpanded)
      if settledExpanded {
        ForEach(records, id: \.identity) { record in
          let source = resolved(record)
          let restoreLabel = source == nil ? "Clear choice" : "Unsettle"
          let target =
            source
            ?? FocusTarget(
              identity: record.identity, reference: record.localReference, title: "Unavailable item"
            )
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(target.title).foregroundStyle(.primary)
              Text("Hidden on this day in Today").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              changeFocus(source == nil ? nil : .active, target: target)
            } label: {
              Group {
                if source != nil {
                  Image(systemName: "arrow.uturn.backward")
                    .font(ButtonConfiguration.Icon.actionFont)
                    .frame(minWidth: ButtonConfiguration.minimumHitSize)
                } else {
                  Text(restoreLabel)
                }
              }
              .frame(minHeight: ButtonConfiguration.minimumHitSize)
              .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(restoreLabel)
            .accessibilityLabel(
              source == nil ? "Clear unavailable Focus choice" : restoreLabel + " " + target.title)
          }
          .modifier(TodayItemSurface(enabled: true))
          .modifier(
            TodayFocusRowActions(
              enabled: true, settle: {}, ask: source?.subject,
              open: source == nil ? nil : { openAttentionItem(target) },
              delete: source != nil && canDeleteAttention(target)
                ? { requestDeleteAttention(target) } : nil,
              restore: { _ = changeFocus(source == nil ? nil : .active, target: target) },
              restoreLabel: restoreLabel)
          )
          .listRowSeparator(.hidden)
        }
      }
    }

    /// Resolve content from the current source, never from an overlay copy or a title match.
    private func resolved(_ record: FocusRecord) -> FocusTarget? {
      for task in tasks where !task.isDone {
        let candidate = target(task)
        if candidate.identity == record.identity { return candidate }
      }
      for event in events {
        let start = record.identity.occurrence ?? event.start
        if event.repeats != nil,
          !event.occurrences(in: DateInterval(start: start, duration: 1)).contains(start)
        {
          continue
        }
        let candidate = target(event, start: start)
        if candidate.identity == record.identity { return candidate }
      }
      if let alarm = alarms.first(where: {
        TodayFocus.reference($0.persistentModelID) == record.localReference
      }), let fireDate = record.identity.occurrence {
        let candidate = target(alarm, fireDate: fireDate)
        if candidate.identity == record.identity { return candidate }
      }
      if let event = calendar.cachedFocusEvent(
        identity: record.identity, reference: record.localReference)
      {
        return FocusTarget(
          identity: record.identity, reference: record.localReference, title: event.title)
      }
      return nil
    }

    private func openAttentionItem(_ target: FocusTarget) {
      if let task = tasks.first(where: { self.target($0).identity == target.identity }) {
        openTask(task)
        return
      }
      if let alarm = alarms.first(where: {
        self.target($0, fireDate: target.identity?.occurrence ?? now).identity == target.identity
      }) {
        openAlarm(alarm)
        return
      }
      if let event = events.first(where: {
        self.target($0, start: target.identity?.occurrence ?? $0.start).identity == target.identity
      }) {
        openEvent(event)
        return
      }
      if let identity = target.identity,
        let event = calendar.cachedFocusEvent(identity: identity, reference: target.reference),
        let native = calendar as? any NativeCalendarService
      {
        native.edit(
          identifier: event.eventIdentifier, start: event.start, end: nil,
          onComplete: nil)
      } else {
        toast?.showNotice("This source is unavailable. Reconnect and try again.")
      }
    }

    private func attentionEntry(_ target: FocusTarget) -> CalEntry? {
      guard let identity = target.identity else { return nil }
      // A local identity carries its model ID. Prefer that candidate, but decoded
      // PersistentIdentifier equality can differ after migration: retain the full
      // canonical identity lookup as a fallback, and always revalidate the candidate.
      let localKind = identity.provider == "today.local" ? identity.calendar : nil
      let localID: PersistentIdentifier? =
        localKind == nil
        ? nil
        : identity.item.data(using: .utf8).flatMap {
          try? JSONDecoder().decode(PersistentIdentifier.self, from: $0)
        }
      func matching<Model: PersistentModel>(
        _ models: [Model], kind: String, matches: (Model) -> Bool
      ) -> Model? {
        guard localKind == nil || localKind == kind else { return nil }
        if let localID, let candidate = models.first(where: { $0.persistentModelID == localID }),
          matches(candidate)
        {
          return candidate
        }
        return models.first(where: matches)
      }
      if let task = matching(
        tasks, kind: "reminder",
        matches: {
          self.target($0).identity == identity
        })
      {
        let start = task.due ?? now
        return CalEntry(
          id: target.id, source: .task(task), title: task.title,
          start: start, end: start.addingTimeInterval(Double(task.durationMinutes) * 60),
          isAllDay: false, color: .accentColor, repeats: task.repeats != nil)
      }
      if let alarm = matching(
        alarms, kind: "alarm",
        matches: {
          self.target($0, fireDate: identity.occurrence ?? now).identity == identity
        })
      {
        let start = identity.occurrence ?? now
        return CalEntry(
          id: target.id, source: .alarm(alarm), title: target.title,
          start: start, end: start.addingTimeInterval(60), isAllDay: false, color: .accentColor,
          repeats: false)
      }
      if let event = matching(
        events, kind: "event",
        matches: {
          self.target($0, start: identity.occurrence ?? $0.start).identity == identity
        })
      {
        let start = identity.occurrence ?? event.start
        return CalEntry(
          id: "r\(event.persistentModelID.hashValue)@\(start.timeIntervalSince1970)",
          source: .local(event), title: event.title, start: start,
          end: start.addingTimeInterval(event.duration), isAllDay: event.isAllDay,
          color: calendar.cachedEvent(
            externalID: event.externalID ?? "", occurrence: start)?.color ?? .blue,
          repeats: event.repeats != nil)
      }
      if let ref = target.reference, ref.hasPrefix("eventkit:"),
        let event = calendar.cachedEvent(
          externalID: String(ref.dropFirst("eventkit:".count)), occurrence: identity.occurrence),
        self.target(event).identity == identity
      {
        return CalEntry(
          id: event.id, source: .system(event.eventIdentifier), title: event.title,
          location: event.location, start: event.start, end: event.end, isAllDay: event.isAllDay,
          color: event.color, calendarTitle: event.calendarTitle, repeats: event.repeats)
      }
      return nil
    }

    private func canDeleteAttention(_ target: FocusTarget) -> Bool {
      guard let entry = attentionEntry(target) else { return false }
      return switch entry.source {
      case .task(let task):
        switch reminders.focusIdentity(task) {
        case .available, .localOnly: true
        default: false
        }
      case .alarm: true
      case .local(let event):
        event.externalID == nil || calendar.cachedCanDelete(externalID: event.externalID)
      case .system(let id): calendar.cachedCanDelete(externalID: id)
      }
    }

    /// A one-off event is deleted at once (Undo toast); only a repeating one asks "this event or the series?".
    private func requestEventDelete(_ entry: CalEntry) {
      if entry.repeats {
        pendingDelete = entry
      } else {
        actions.delete(entry, span: .futureEvents, context: context, toast: toast)
      }
    }

    private func requestDeleteAttention(_ target: FocusTarget) {
      guard canDeleteAttention(target), let entry = attentionEntry(target) else {
        toast?.showNotice("This source is unavailable or read-only. Its item was kept.")
        return
      }
      switch entry.source {
      case .task(let task): requestDelete(task)
      case .alarm(let alarm): _ = actions.delete(alarm, context: context, toast: toast)
      case .local, .system: requestEventDelete(entry)
      }
    }

    /// Oldest deadline first.
    private var overdue: [OneTask] {
      tasks.filter { plannerIsOverdue($0, now: now, calendar: cal) && !isHidden(target($0)) }.sorted
      {
        ($0.due ?? .distantPast) < ($1.due ?? .distantPast)
      }
    }
  }

  /// What one day holds, in the order the day view shows it.
  struct DayItems {
    var allDay: [OneEvent]
    var externalAllDay: [ExternalEvent]
    var timeline: [TimelineItem]
    /// Due this day with no time, and no free gap left to suggest one.
    var anytime: [OneTask]
  }

  enum TimelineItem: Identifiable {
    case event(OneEvent, Date)
    case external(ExternalEvent)
    /// A reminder, at the time it is due.
    case due(OneTask)
    /// A ring; on a past day, when it was stopped (if Activity recorded the Stop).
    case alarm(OneAlarm, Date, Date?)
    /// A past day: a reminder Today still has, completed that day, at its completion time.
    case done(OneTask, Date)
    /// A past day: a completion recorded in Activity whose reminder is gone or has moved on (repeating).
    case completed(DayHistory.Completion)
    /// A past day: a recorded Stop of an alarm that no longer rings that day.
    case stoppedAlarm(DayHistory.AlarmStop)
    /// A past day: an event deleted after it had started.
    case deletedEvent(DayHistory.DeletedEvent)
    /// Free time of 30 minutes or more, from now on.
    case gap(DateInterval)
    case nowMarker(Date)

    var id: AnyHashable {
      switch self {
      case .event(let e, let d): return [AnyHashable(ObjectIdentifier(e)), AnyHashable(d)]
      case .external(let e): return e.id
      case .due(let t): return ["due", AnyHashable(ObjectIdentifier(t))]
      case .alarm(let a, let d, _): return [AnyHashable(ObjectIdentifier(a)), AnyHashable(d)]
      case .done(let t, _): return ["done", AnyHashable(ObjectIdentifier(t))]
      case .completed(let c): return ["completed", c.id]
      case .stoppedAlarm(let s): return ["stopped", s.id]
      case .deletedEvent(let e): return ["deletedEvent", e.id]
      case .gap(let free): return ["gap", AnyHashable(free.start)]
      case .nowMarker: return "now"
      }
    }

    var isNow: Bool { if case .nowMarker = self { true } else { false } }

    /// Something on the day's plan, as opposed to free time or the Now line.
    var isPlanned: Bool {
      switch self {
      case .gap, .nowMarker: false
      default: true
      }
    }

    var start: Date {
      switch self {
      case .event(_, let d): return d
      case .external(let e): return e.start
      case .due(let t): return t.due ?? .distantFuture
      case .alarm(_, let d, _): return d
      case .done(_, let d): return d
      case .completed(let c): return c.at
      case .stoppedAlarm(let s): return s.at
      case .deletedEvent(let e): return e.start
      case .gap(let free): return free.start
      case .nowMarker(let d): return d
      }
    }
  }

  /// Small section label for the day view, so headers take less space than the default plain-list header.
  struct AgendaHeader: View {
    let title: String
    var isInline = false
    package var body: some View {
      Text(title)
        .font(isInline ? .caption.weight(.semibold) : .footnote.weight(.semibold))
        // secondaryLabel, not .secondary: a list header is already dimmed, and .secondary on top read too faint.
        .foregroundStyle(Color(.secondaryLabel))
        .textCase(nil)
        .listRowInsets(
          EdgeInsets(top: isInline ? 2 : 8, leading: 20, bottom: isInline ? 0 : 2, trailing: 20))
    }
  }

  /// Heads the reminders that are due this day with no time.
  struct AnytimeLabel: View {
    let title: String
    package var body: some View {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 20))
    }
  }

  /// Free time between items: one quiet line, aligned with the titles.
  struct FreeRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    let free: DateInterval
    package var body: some View {
      Text(DaySchedule.freeLabel(free.duration))
        .font(AgendaRowStyle.detail)
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.leading, 68)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityLabel(
          DaySchedule.freeLabel(free.duration) + " from "
            + free.start.plannerFormatted(
              date: .omitted, time: .shortened, runtime: presentation.runtime))
    }
  }

#endif

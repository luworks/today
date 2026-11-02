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

  /// One day's view: active events, tasks and alarms stay directly visible in a single timeline.
  /// On today a red "N overdue" line sits above the timeline (tap to show the rows, Tidy to reschedule them all).
  /// A past day also shows what was done on it, rebuilt from Activity (`DayHistory`): reminders completed that day at
  /// their completion time, alarms that were stopped, and events deleted after they happened.
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
    /// What Activity says happened on `day` (past days only), and the day it was read for.
    @State private var history = DayHistory()
    @State private var historyDay: Date?
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
          scrollToNow(proxy)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshClock() }
      }
      // Re-read when the day changes, the app comes back (the outbox brings in alarm stops) or a reminder changes.
      .task(
        id:
          "\(cal.startOfDay(for: day).timeIntervalSince1970)|\(scenePhase == .active)|\(tasks.count)"
      ) {
        loadHistory()
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

    /// The Today tab on today (not the Calendar tab, not another day).
    private var isTodayTab: Bool { !showsWeekStrip && cal.isDate(day, inSameDayAs: now) }

    private var list: some View {
      let items = items(on: day, now: now)
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
                attention: attention(canDelete: canDelete($0))
              )
            }
            ForEach(items.externalAllDay) {
              ExternalEventRow(
                event: $0, pendingDelete: $pendingDelete, calendar: calendar, travel: travel,
                attention: attention(canDelete: canDelete($0))
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
      }
      .listStyle(.plain)
      // Interactive rows own their 44pt targets. Today captions and gaps use their natural text height.
      .environment(\.defaultMinListRowHeight, showsWeekStrip ? 24 : 0)
      .listSectionSpacing(showsWeekStrip ? 6 : 0)
      .scrollContentBackground(.hidden)
      .entryDeleteDialog($pendingDelete)
    }

    @ViewBuilder
    private func timelineContent(_ items: DayItems) -> some View {
      if items.timeline.isEmpty, items.anytime.isEmpty {
        Text("Nothing planned").foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
      }
      ForEach(items.timeline) { timelineRow($0, on: day) }
      if !items.anytime.isEmpty {
        AnytimeLabel(title: cal.isDate(day, inSameDayAs: now) ? "Anytime today" : "Anytime")
        ForEach(items.anytime) { task in
          TaskRow(
            task: task, compact: true, agendaDay: day, onDelete: { requestDelete(task) },
            open: openTask, attention: attention(canDelete: canDelete(task))
          )
        }
      }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem, on rowDay: Date) -> some View {
      switch item {
      case .event(let event, let start):
        EventRow(
          event: event, start: start, pendingDelete: $pendingDelete, open: openEvent,
          calendar: calendar, travel: travel,
          attention: attention(canDelete: canDelete(event))
        )
      case .external(let e):
        ExternalEventRow(
          event: e, pendingDelete: $pendingDelete, calendar: calendar, travel: travel,
          attention: attention(canDelete: canDelete(e))
        )
      case .due(let task):
        TaskRow(
          task: task, showsTime: true, time: task.due, compact: true, agendaDay: rowDay,
          onDelete: { requestDelete(task) }, open: openTask,
          attention: attention(canDelete: canDelete(task))
        )
      case .alarm(let alarm, let date, let stoppedAt):
        AlarmMarkRow(
          alarm: alarm, date: date, open: openAlarm,
          attention: attention(canDelete: true),
          onDelete: showsWeekStrip
            ? nil : { _ = actions.delete(alarm, context: context, toast: toast) },
          stoppedAt: stoppedAt)
      case .done(let task, let doneAt):
        TaskRow(
          task: task, showsTime: true, time: doneAt, compact: true, agendaDay: rowDay,
          onDelete: { requestDelete(task) }, open: openTask,
          attention: attention(canDelete: canDelete(task))
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

    // MARK: One day's items

    private func items(on day: Date, now: Date) -> DayItems {
      let external = calendar.events(on: day, excluding: Set(events.compactMap(\.externalID)))
      var timeline: [TimelineItem] = []
      var busy: [DateInterval] = []
      for e in events where !e.isAllDay {
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
        allDay: events.filter { $0.isAllDay && !$0.occurs(on: day, calendar: cal).isEmpty },
        externalAllDay: external.filter(\.isAllDay),
        // At the same minute the Now line comes first, so free time from now sits under it.
        timeline: timeline.sorted {
          ($0.start, $0.isNow ? 0 : 1) < ($1.start, $1.isNow ? 0 : 1)
        },
        anytime: anytime)
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

    // MARK: Today row commands

    private func attention(canDelete: Bool) -> TodayRowAttention? {
      showsWeekStrip ? nil : TodayRowAttention(canDelete: canDelete)
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

    private var overdueRows: some View {
      ForEach(overdue) { task in
        TaskRow(
          task: task, compact: true, agendaDay: day, onDelete: { requestDelete(task) },
          open: openTask, attention: attention(canDelete: canDelete(task))
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

    /// Oldest deadline first.
    private var overdue: [OneTask] {
      tasks.filter { plannerIsOverdue($0, now: now, calendar: cal) }.sorted {
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
        .font(.caption)
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

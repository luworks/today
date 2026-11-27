#if os(iOS)
  import One
  import TodayPlannerUI
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData
  import UIKit

  package struct DayAgenda: View {
    private let actions: PlannerActions
    private let calendar: any CalendarService
    private let timers: any TimerService
    private let reminders: any ReminderService
    private let ledger: Ledger
    private let travel: any TravelTimeProviding
    private let showsUndoToast: Bool
    @Environment(PlannerPresentation.self) private var presentation
    @Binding var day: Date
    @Binding private var nowRequest: Bool
    /// Opens the Timer tab (a tap on a running timer's row).
    let openTimer: @MainActor () -> Void
    let openTask: @MainActor (OneTask) -> Void
    let openEvent: @MainActor (OneEvent) -> Void
    let openAlarm: @MainActor (OneAlarm) -> Void
    /// Opens "Tidy overdue" for these reminders (a preview; nothing changes until Apply). Nil hides the button.
    let openTidy: (@MainActor ([OneTask]) -> Void)?

    package init(
      day: Binding<Date>, nowRequest: Binding<Bool> = .constant(false),
      openTask: @escaping @MainActor (OneTask) -> Void,
      openEvent: @escaping @MainActor (OneEvent) -> Void,
      openAlarm: @escaping @MainActor (OneAlarm) -> Void,
      openTimer: @escaping @MainActor () -> Void, actions: PlannerActions,
      calendar: any CalendarService, timers: any TimerService, reminders: any ReminderService,
      ledger: Ledger, travel: any TravelTimeProviding, presentation: PlannerPresentation,
      showsUndoToast: Bool = false,
      openTidy: (@MainActor ([OneTask]) -> Void)? = nil
    ) {
      self.actions = actions
      self.calendar = calendar
      self.timers = timers
      self.reminders = reminders
      self.ledger = ledger
      self.travel = travel
      self.showsUndoToast = showsUndoToast
      _now = State(initialValue: presentation.now)
      _showsAlarms = AppStorage(
        wrappedValue: true, SettingsKey.showAlarms, store: presentation.defaults)
      _showsWeather = AppStorage(
        wrappedValue: Preferences.weatherSummary, Preferences.weatherSummaryKey,
        store: presentation.defaults)
      _showsSettle = AppStorage(
        wrappedValue: Preferences.showSettle, Preferences.showSettleKey,
        store: presentation.defaults)
      _showsFreeTime = AppStorage(
        wrappedValue: Preferences.showFreeTime, Preferences.showFreeTimeKey,
        store: presentation.defaults)
      _freeRowMinutes = AppStorage(
        wrappedValue: Preferences.freeRowMinutes, Preferences.freeRowMinutesKey,
        store: presentation.defaults)
      _day = day
      _nowRequest = nowRequest
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
    @AppStorage(Preferences.weatherSummaryKey) private var showsWeather = Preferences.weatherSummary
    @AppStorage(Preferences.showSettleKey) private var showsSettle = Preferences.showSettle
    @AppStorage(Preferences.showFreeTimeKey) private var showsFreeTime = Preferences.showFreeTime
    @AppStorage(Preferences.freeRowMinutesKey) private var freeRowMinutes = Preferences
      .freeRowMinutes
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var drag = TimelineDragModel()
    @State private var frozenDayItems: DayItems?
    @State private var retryTime: Date?
    /// What Activity says happened on `day` (past days only), and the day it was read for.
    @State private var history = DayHistory()
    @State private var historyDay: Date?
    @State private var freeChoice: FreeTimeChoice?
    @State private var settledOpen = false
    @State private var earlierOpen = false
    @State private var entry: Date?
    @State private var doneAnchor: Set<PersistentIdentifier> = []
    @State private var parts = DayPartDisclosure()
    @State private var viewport = TimelineViewport()
    @State private var picked: AnyHashable?
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?

    package var body: some View {
      ScrollViewReader { proxy in
        let dayItems = frozenDayItems ?? items(on: day, now: now)
        let plan = makePlan(dayItems)
        let rows = partRows(plan)
        VStack(spacing: 0) {
          if !isPastDay, !plan.marks.isEmpty { ribbon(plan, proxy: proxy) }
          list(items: dayItems, rows: rows, earlier: plan.earlier)
            .contentMargins(
              .bottom, isToday ? TodayTimeline.continuationHeight : 0, for: .scrollContent
            )
            .overlay(alignment: .bottom) {
              if isToday {
                TodayContinuation(viewport: viewport, disabled: drag.session != nil || timeBusy) {
                  id in
                  withAnimation(reduceMotion ? nil : .snappy) {
                    proxy.scrollTo(id, anchor: .top)
                  }
                }
              }
            }
        }
        .overlay(alignment: .bottom) {
          if showsUndoToast { UndoToastView() }
        }
        .onAppear {
          refreshClock()
          enter()
        }
        .task(id: nowRequest) {
          guard nowRequest else { return }
          refreshClock()
          guard isToday else { return }
          enter()
          withAnimation(reduceMotion ? nil : .snappy) {
            proxy.scrollTo(TimelineItem.nowID, anchor: UnitPoint(x: 0.5, y: 0.22))
          }
          nowRequest = false
        }
        .onChange(of: day) { _, _ in
          enter()
          picked = nil
          showsAllOverdue = false
          earlierOpen = false
          timeRequest = nil
          pendingTime = nil
          drag.end()
          frozenDayItems = nil
          retryTime = nil
        }
        .onChange(of: timelineSpans(rows, earlier: plan.earlier), initial: true) { _, spans in
          viewport.setSpans(spans)
        }
        .onChange(of: continuationIDs(rows), initial: true) { _, ids in
          viewport.setUpcoming(ids)
        }
        .onChange(of: settledTodayIDs.isEmpty) { _, empty in
          if empty { settledOpen = false }
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
      .overlay { TimelineDragOverlay(model: drag).allowsHitTesting(false) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          refreshClock()
          enter()
        }
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
      .task(id: [showsWeather, isTodayTab, scenePhase == .active]) {
        weather.update(enabled: showsWeather && isTodayTab && scenePhase == .active)
      }
      .onDisappear {
        weather.update(enabled: false)
      }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
          refreshClock()
          if !Task.isCancelled, showsWeather, isTodayTab, scenePhase == .active {
            weather.update(enabled: true)
          }
        }
      }
    }

    private func enter() {
      entry = presentation.now
      doneAnchor = Set(tasks.filter(\.isDone).map(\.persistentModelID))
    }

    private func refreshClock() {
      let next = presentation.now
      if !cal.isDate(next, inSameDayAs: now) {
        parts = DayPartDisclosure()
        settledOpen = false
        picked = nil
        entry = next
      }
      day = presentation.runtime.refreshedTodayDay(day, previousNow: now, now: next)
      now = next
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
    private var isTodayTab: Bool { cal.isDate(day, inSameDayAs: now) }

    private func list(
      items: DayItems, rows: [DayPartRow<TimelineItem>], earlier: [TimelineItem]
    ) -> some View {
      List {
        if isTodayTab { TodayTimerRows(controller: timers, open: openTimer) }
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
        if isTodayTab, !overdue.isEmpty { overdueSection }
        if isTodayTab, showsFreeTime, let conclusion = deadlineConclusion(items) {
          conclusionLine(conclusion, anytime: items.anytime)
        }
        if !items.allDay.isEmpty || !items.externalAllDay.isEmpty {
          Section {
            AgendaHeader(title: "All day")
              .accessibilityAddTraits(.isHeader)
              .listRowSeparator(.hidden)
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
          }
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
        earlierSection(earlier)
        timelineContent(items, rows: rows)
        settledSection
      }
      .listStyle(.plain)
      .transaction(value: settledTodayIDs) { transaction in
        if settlesHere { transaction.animation = nil }
      }
      .animation(reduceMotion ? nil : .snappy, value: items.timeline.map(\.start))
      .environment(\.defaultMinListRowHeight, 0)
      .listSectionSpacing(0)
      .scrollContentBackground(.hidden)
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: { frame in
        viewport.setList(frame, footer: isToday ? TodayTimeline.continuationHeight : 0)
      }
      .pullToAsk()
      .background {
        TimelineHoldDragInstaller(
          model: drag, canLift: { canLift(at: $0, rows: rows) },
          touched: {}, began: { beginDrag(at: $0) },
          ended: { endDrag(cancelled: $0) })
      }
      .entryDeleteDialog($pendingDelete)
      .sheet(item: $freeChoice) { freeSheet($0) }
    }

    private func timelineSpans(
      _ rows: [DayPartRow<TimelineItem>], earlier: [TimelineItem]
    ) -> [AnyHashable: DateInterval] {
      var spans: [AnyHashable: DateInterval] = [:]
      if earlierOpen {
        for item in earlier { spans[item.id] = item.span }
      }
      for row in rows {
        if case .item(let item, _) = row { spans[row.id] = item.span }
      }
      return spans
    }

    private func continuationIDs(_ rows: [DayPartRow<TimelineItem>]) -> [AnyHashable] {
      guard isToday else { return [] }
      return rows.compactMap { row in
        guard case .item(let item, _) = row, item.start >= now, item.isPlanned,
          !timelineEntry(item).isDone
        else { return nil }
        return row.id
      }
    }

    @ViewBuilder
    private func timelineContent(_ items: DayItems, rows: [DayPartRow<TimelineItem>]) -> some View {
      if isPastDay {
        if historyDay == cal.startOfDay(for: day) {
          DayPartRows(
            rows: DayPart.rows(
              history.facts.filter(\.isPrimary), day: day, calendar: cal, start: \.at,
              isPlanned: { _ in true }, isOpen: isOpen), drag: drag, toggle: togglePart
          ) { fact in
            HistoricalFactRow(fact: fact, todayStyle: true)
          }
          let changes = history.facts.filter { !$0.isPrimary }
          if !changes.isEmpty {
            DisclosureGroup("Changes (\(changes.count))") {
              ForEach(changes) { fact in HistoricalFactRow(fact: fact, todayStyle: true)
              }
            }
          }
          if history.facts.isEmpty {
            Text("No recorded actions").foregroundStyle(.secondary)
          }
        }
      } else {
        if items.timeline.isEmpty, items.anytime.isEmpty {
          Text("Nothing planned").foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
        }
        DayPartRows(rows: rows, drag: drag, viewport: viewport, toggle: togglePart) { item in
          dayItemRow(item)
        }
      }
    }

    @ViewBuilder
    private func earlierSection(_ items: [TimelineItem]) -> some View {
      if !items.isEmpty {
        TodaySectionHeader(
          title: "Earlier", count: items.count, isOpen: earlierOpen, identifier: "today.earlier"
        ) {
          withAnimation(reduceMotion ? nil : .snappy) { earlierOpen.toggle() }
        }
        .id("today.earlier")
        if earlierOpen {
          ForEach(items) { item in
            timelineRow(item, on: day)
              .modifier(drag.frameReader(item.id, viewport: viewport))
              .listRowBackground(Color.clear)
          }
        }
      }
    }

    private func keepsWhenClosed(_ item: TimelineItem) -> Bool {
      guard !item.staysWhenClosed, isToday else { return item.staysWhenClosed }
      let mark = timelineEntry(item)
      return TodayTimeline.isOpenPast(mark, now: now)
        || (mark.kind == .event && mark.start <= now && mark.stop >= entryTime)
    }

    private func partRows(_ plan: DayPlan) -> [DayPartRow<TimelineItem>] {
      guard let session = drag.session else {
        return DayPart.rows(
          shownRows(plan), day: day, calendar: cal, start: \.start, isPlanned: \.isPlanned,
          isOpen: isOpen, keepsWhenClosed: keepsWhenClosed)
      }
      let stop = session.stops[drag.stopIndex]
      var rows = session.anchors
      rows.insert(session.item, at: stop.index)
      return DayPart.rows(
        rows, day: day, calendar: cal,
        start: { $0.id == session.item.id ? stop.target : $0.start }, isPlanned: \.isPlanned,
        isOpen: isOpen, keepsWhenClosed: { keepsWhenClosed($0) || $0.id == session.item.id })
    }

    private var entryTime: Date { entry ?? now }

    private func isOpen(_ part: DayPart) -> Bool {
      parts.isOpen(part, day: day, entry: entryTime, calendar: cal)
    }

    private func togglePart(_ part: DayPart) {
      guard drag.session == nil, !timeBusy else { return }
      withAnimation(reduceMotion ? nil : .snappy) {
        parts.toggle(part, day: day, entry: entryTime, calendar: cal)
      }
    }

    private func shownRows(_ plan: DayPlan) -> [TimelineItem] {
      plan.rows.map { row in
        switch row {
        case .item(let index): plan.planned[index]
        case .free(let index): .gap(plan.free[index])
        case .now: .nowMarker(now, nil)
        case .nowWithFree(let index): .nowMarker(now, plan.free[index])
        }
      }
    }

    private var isToday: Bool { cal.isDate(day, inSameDayAs: now) }

    private func makePlan(_ items: DayItems) -> DayPlan {
      let planned = items.timeline.filter(\.isPlanned)
      let free = items.timeline.compactMap { item -> DateInterval? in
        if case .gap(let gap) = item { return gap }
        return nil
      }
      let marks = planned.map(timelineEntry)
      let current = isToday ? now : nil
      let entryTime = current.map { entry ?? $0 }
      let earlier = planned.indices.compactMap { index in
        TodayTimeline.isListed(marks[index], entry: entryTime) ? nil : planned[index]
      }
      return DayPlan(
        earlier: earlier, planned: planned, free: free, marks: marks,
        rows: TodayTimeline.rows(items: marks, free: free, now: current, entry: entryTime),
        range: TodayTimeline.ribbonRange(items: marks, day: day, calendar: cal))
    }

    private func timelineEntry(_ item: TimelineItem) -> TodayTimeline.Item {
      switch item {
      case .event(let event, let start):
        TodayTimeline.Item(
          start: start, end: start.addingTimeInterval(event.duration), kind: .event)
      case .external(let event):
        TodayTimeline.Item(start: event.start, end: max(event.start, event.end), kind: .event)
      case .due(let task):
        TodayTimeline.Item(
          start: item.start, kind: .reminder, isDone: task.isDone,
          doneAtEntry: task.isDone && doneAnchor.contains(task.persistentModelID))
      case .alarm(_, let date, _): TodayTimeline.Item(start: date, kind: .alarm)
      case .gap(let gap): TodayTimeline.Item(start: gap.start, kind: .reminder)
      case .nowMarker(let date, _): TodayTimeline.Item(start: date, kind: .reminder)
      }
    }

    private func ribbon(_ plan: DayPlan, proxy: ScrollViewProxy) -> some View {
      let current = isToday ? now : nil
      let marks = zip(plan.planned, plan.marks).map { item, entry in
        let repeats: Bool = if case .due(let task) = item { task.repeats != nil } else { false }
        return DayRibbon.Mark(
          start: entry.start, end: entry.end, kind: entry.kind, repeats: repeats,
          faded: entry.isDone
            || current.map { entry.kind != .reminder && entry.stop < $0 } ?? false,
          late: TodayTimeline.isOpenPast(entry, now: current))
      }
      let targets = ribbonTargets(plan)
      return DayRibbon(
        marks: marks, range: plan.range, calendar: cal, now: current, viewport: viewport,
        label: {
          $0.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
        },
        pick: { pick($0, animated: $1, targets: targets, proxy: proxy) },
        showNow: {
          withAnimation(reduceMotion ? nil : .snappy) {
            proxy.scrollTo(TimelineItem.nowID, anchor: .center)
          }
        }
      )
      .padding(.horizontal, 16)
      .disabled(drag.session != nil || timeBusy)
    }

    private struct RibbonTarget {
      let id: AnyHashable
      let span: DateInterval
      let section: (part: DayPart, id: AnyHashable)?
      var isEarlier = false
    }

    private func ribbonTargets(_ plan: DayPlan) -> [RibbonTarget] {
      var targets: [RibbonTarget] = []
      var section: (part: DayPart, id: AnyHashable)?
      var useHeader = false
      for row in DayPart.rows(
        shownRows(plan), day: day, calendar: cal, start: \.start, isPlanned: \.isPlanned)
      {
        switch row {
        case .label(let part, _, _):
          section = (part, row.id)
          useHeader = true
        case .item(let item, let part):
          guard let span = item.span else { continue }
          if part == nil { section = nil }
          targets.append(
            RibbonTarget(
              id: (useHeader ? section?.id : nil) ?? row.id, span: span, section: section))
          useHeader = false
        }
      }
      if !plan.earlier.isEmpty {
        targets.append(
          contentsOf: plan.earlier.compactMap { item in
            item.span.map {
              RibbonTarget(id: item.id, span: $0, section: nil, isEarlier: true)
            }
          })
        targets = targets.enumerated().sorted { lhs, rhs in
          (lhs.element.span.start, lhs.offset) < (rhs.element.span.start, rhs.offset)
        }.map(\.element)
      }
      return targets
    }

    private func pick(
      _ date: Date, animated: Bool, targets: [RibbonTarget], proxy: ScrollViewProxy
    ) -> Bool {
      guard let index = TodayTimeline.scrollTarget(for: date, in: targets.map(\.span)) else {
        return false
      }
      let target = targets[index]
      let closed = target.section.flatMap { isOpen($0.part) ? nil : $0 }
      let revealEarlier = target.isEarlier && !earlierOpen
      let id = revealEarlier ? AnyHashable("today.earlier") : (closed?.id ?? target.id)
      let changed = id != picked
      guard changed || animated else { return false }
      if changed { picked = id }
      withAnimation(animated && !reduceMotion ? .snappy : nil) {
        if animated, revealEarlier { earlierOpen = true }
        if animated, let closed {
          parts.set(closed.part, open: true, day: day, calendar: cal)
        }
        proxy.scrollTo(id, anchor: .top)
      }
      return changed
    }

    @ViewBuilder
    private func dayItemRow(_ item: TimelineItem) -> some View {
      if !isPastDay, dragTiming(item) != nil {
        timelineRow(item, on: day)
          .environment(\.agendaTimeEdit, { editTime(item) })
          .accessibilityAction(named: "Change time") { editTime(item) }
          .modifier(TimelineDragRowChrome(model: drag, id: item.id))
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
          .listRowSeparator(.hidden)
          .disabled(timeBusy)
      } else {
        timelineRow(item, on: day)
      }
    }

    private func canLift(at point: CGPoint, rows: [DayPartRow<TimelineItem>]) -> Bool {
      guard let id = dragHit(at: point) else { return false }
      for row in rows where row.id == id {
        if case .item(let item, _) = row { return dragTiming(item) != nil }
      }
      return false
    }

    private func dragHit(at point: CGPoint) -> AnyHashable? {
      guard !isPastDay, !timeBusy, pendingTime == nil else { return nil }
      return drag.rowID(at: point)
    }

    private func beginDrag(at point: CGPoint) -> Bool {
      guard let id = dragHit(at: point) else { return false }
      let items = items(on: day, now: now)
      let plan = makePlan(items)
      let others = shownRows(plan).filter { if case .gap = $0 { false } else { true } }
      guard let originalIndex = others.firstIndex(where: { $0.id == id }) else { return false }
      let item = others[originalIndex]
      guard let timing = dragTiming(item) else { return false }
      prepareTime(item, timing: timing)
      guard timeRequest != nil else { return false }
      var anchors = others
      anchors.remove(at: originalIndex)
      let stops = TimelineDropPlan.stops(
        anchors: anchors.map(\.dropAnchor), originalIndex: originalIndex, timing: timing, day: day,
        calendar: cal
      ).filter { stop in
        // Hidden rows still constrain time, but only visible rows can provide a drag boundary.
        guard stop.index != originalIndex else { return true }
        guard isOpen(DayPart.of(stop.target, day: day, calendar: cal)) else { return false }
        guard stop.index > 0 else { return true }
        let boundary = anchors[stop.index - 1]
        return keepsWhenClosed(boundary)
          || isOpen(DayPart.of(boundary.start, day: day, calendar: cal))
      }
      guard let original = stops.firstIndex(where: { $0.index == originalIndex }) else {
        return false
      }
      frozenDayItems = items
      return drag.begin(
        TimelineDragModel.Session(
          item: item, timing: timing, anchors: anchors, stops: stops, originalStop: original,
          row: AnyView(timelineRow(item, on: day)),
          overlaps: { date in
            anchors.contains { $0.overlaps(date, timing: timing) }
          }),
        at: point, reduceMotion: reduceMotion)
    }

    private func endDrag(cancelled: Bool) {
      drag.release(cancelled: cancelled, reduceMotion: reduceMotion) { target in
        guard let target, timeRequest != nil else {
          finishDrag()
          return
        }
        if (timeRequest?.attendees ?? 0) > 0 {
          pendingTime = target
          finishDrag()
        } else {
          // The frozen list holds the new order until the source has saved, so nothing jumps back.
          submitTime(target, then: finishDrag)
        }
      }
    }

    private func finishDrag() {
      drag.end()
      frozenDayItems = nil
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
          onDelete: { _ = actions.delete(alarm, context: context, toast: toast) },
          stoppedAt: stoppedAt)
      case .gap(let free): FreeRow(free: free) { openFree(free, from: "today.freeRow") }
      case .nowMarker(let date, let free):
        NowRow(date: date, free: free) {
          if let free { openFree(free, from: "today.freeRow") }
        }
        .id(TimelineItem.nowID)
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
      case .due(let task):
        guard !task.isDone else { return nil }
        duration = 0
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

    private func submitTime(_ date: Date, then finished: @escaping () -> Void = {}) {
      guard !timeBusy, let request = timeRequest else {
        finished()
        return
      }
      timeBusy = true
      retryTime = date
      Task { @MainActor in
        defer {
          timeBusy = false
          finished()
        }
        do {
          let time = date.plannerFormatted(
            date: .omitted, time: .shortened, runtime: presentation.runtime)
          try await request.apply(date, label: "Moved to \(time)", toast: toast)
          timeRequest = nil
          retryTime = nil
        } catch { timeError = error.localizedDescription }
      }
    }

    // MARK: One day's items

    private func items(on day: Date, now: Date) -> DayItems {
      if isPastDay {
        // Past rows contain only recorded actions, never mutable source models or bare plans.
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
      if !isPastDay {
        for task in tasks where task.isDone {
          guard let due = task.due, cal.isDate(due, inSameDayAs: day),
            plannerDueHasTime(task, calendar: presentation.calendar)
          else { continue }
          timeline.append(.due(task))
        }
      }
      anytime.sort { ($0.flagged ? 0 : 1, $0.createdAt) < ($1.flagged ? 0 : 1, $1.createdAt) }
      if showsFreeTime {
        timeline += DaySchedule.freeGaps(
          busy: busy, day: day, now: now,
          minimum: Preferences.freeRowMinutes(stored: freeRowMinutes), calendar: cal
        ).map(TimelineItem.gap)
      }
      let rings =
        showsAlarms
        ? CalendarAlarms.occurrences(of: alarms.map(\.spec), on: day, now: now, calendar: cal)
        : []
      timeline += rings.map { ring in
        TimelineItem.alarm(alarms[ring.index], ring.date, nil)
      }
      return DayItems(
        allDay: local.filter {
          $0.isAllDay && !$0.occurs(on: day, calendar: cal).isEmpty
            && !isHidden(
              target($0, start: $0.occurs(on: day, calendar: cal).first ?? $0.start), on: day)
        },
        externalAllDay: external.filter { $0.isAllDay && !isHidden(target($0), on: day) },
        timeline: timeline.filter { !isHidden($0, on: day) }.sorted { $0.start < $1.start },
        anytime: anytime.filter { !isHidden(target($0), on: day) })
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
        identity: actions.focus.identity(of: task, reminders: reminders),
        reference: ref, title: task.title, subject: AskSubject(task: task))
    }

    private func target(_ event: OneEvent, start: Date) -> FocusTarget {
      let ref = TodayFocus.reference(event.persistentModelID)
      return FocusTarget(
        identity: actions.focus.identity(of: event, start: start, calendar: calendar),
        reference: ref, title: event.title, subject: AskSubject(event: event, start: start))
    }

    private func target(_ event: ExternalEvent) -> FocusTarget {
      FocusTarget(
        identity: actions.focus.identity(
          ofSystemEvent: event.eventIdentifier, start: event.start, repeats: event.repeats,
          calendar: calendar),
        reference: "eventkit:" + event.eventIdentifier, title: event.title,
        subject: AskSubject(event: event))
    }

    private func target(_ alarm: OneAlarm, fireDate: Date) -> FocusTarget {
      let ref = TodayFocus.reference(alarm.persistentModelID)
      return FocusTarget(
        identity: actions.focus.identity(of: alarm, fireDate: fireDate),
        reference: ref, title: alarm.label.isEmpty ? "Alarm" : alarm.label,
        subject: AskSubject(alarm: alarm))
    }

    /// Settle lives on the Today tab's current day only (`SettleGate`); past and future days never offer or apply it.
    private func settles(on rowDay: Date? = nil) -> Bool {
      SettleGate.applies(to: day, now: now, calendar: cal)
        && SettleGate.applies(to: rowDay ?? day, now: now, calendar: cal)
    }

    private var settlesHere: Bool { settles() }

    /// `target` is built only when the row can be settled; `canDelete` comes straight from the row's own model.
    private func attention(
      _ target: @autoclosure () -> FocusTarget, canDelete: Bool, on rowDay: Date? = nil
    ) -> TodayRowAttention? {
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
      case .gap, .nowMarker: false
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

    private var settledTodayIDs: Set<FocusIdentity> {
      let calendar = cal
      return Set(
        actions.focus.records.lazy.filter {
          $0.state == .settled
            && calendar.isDate($0.agendaDay(calendar: calendar), inSameDayAs: now)
        }.map(\.identity))
    }

    @ViewBuilder
    private var settledSection: some View {
      let settled = settlesHere && showsSettle ? settledRecords.count : 0
      if settled > 0 {
        TodaySectionHeader(
          title: "Settled", count: settled, isOpen: settledOpen, identifier: "focus.settled"
        ) {
          withAnimation(reduceMotion ? nil : .snappy) { settledOpen.toggle() }
        }
        if settledOpen { settledRows }
      }
    }

    private var settledRows: some View {
      ForEach(settledRecords, id: \.identity) { record in
        let source = resolved(record)
        let restoreLabel = source == nil ? "Clear choice" : "Unsettle"
        let target =
          source
          ?? FocusTarget(
            identity: record.identity, reference: record.localReference, title: "Unavailable item"
          )
        HStack {
          Text(target.title).font(AgendaRowStyle.title).foregroundStyle(.secondary)
            .lineLimit(1)
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

    /// An event Undo can bring back is deleted at once (Undo toast); a series or an event with attendees asks first.
    private func requestEventDelete(_ entry: CalEntry) {
      if actions.deleteAsksFirst(entry) {
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

    private func gapReminder(_ task: OneTask) -> GapFit.Reminder {
      GapFit.Reminder(
        minutes: task.durationMinutes, due: task.due,
        dueHasTime: plannerDueHasTime(task, calendar: presentation.calendar),
        repeats: task.repeatRule != nil, flagged: task.flagged)
    }

    private var openTasks: [OneTask] {
      tasks.filter { !$0.isDone && !isHidden(target($0)) }
    }

    private func deadlineConclusion(_ items: DayItems) -> GapFit.Conclusion? {
      let gaps = items.timeline.compactMap { item -> DateInterval? in
        if case .gap(let free) = item { return free }
        return nil
      }
      return GapFit.conclusion(
        reminders: items.anytime.map(gapReminder), gaps: gaps, now: now, calendar: cal)
    }

    private func conclusionLine(_ conclusion: GapFit.Conclusion, anytime: [OneTask]) -> some View {
      let text = conclusion.text(
        title: { anytime.indices.contains($0) ? anytime[$0].title : "" },
        time: {
          $0.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
        })
      return Button {
        if let opening = conclusion.opening { openFree(opening, from: "today.deadlineLine") }
      } label: {
        Text(text)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .allowsHitTesting(conclusion.opening != nil)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      .accessibilityIdentifier("today.deadlineLine")
    }

    private func openFree(_ gap: DateInterval, from source: String) {
      guard !isPastDay else { return }
      ledger.activity.record(ActivityEvents.screenOpen(source))
      freeChoice = FreeTimeChoice(gap: gap)
    }

    private func freeSheet(_ choice: FreeTimeChoice) -> some View {
      let open = openTasks
      let result = GapFit.candidates(
        for: choice.gap, reminders: open.map(gapReminder), now: presentation.now, calendar: cal)
      let format = { (date: Date) in
        date.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
      }
      let span = format(choice.gap.start) + "–" + format(choice.gap.end)
      let rows = (result?.candidates ?? []).map { candidate in
        let task = open[candidate.index]
        let length =
          candidate.fit == .fits
          ? "Fits · " + DurationLabel.text(minutes: task.durationMinutes) : "Length not set"
        let move =
          ledger.timeLabel(task.due, none: "No date") + " → "
          + ledger.timeLabel(result?.start, none: "")
        return FreeTimeSheet.Row(task: task, detail: length + " · " + move)
      }
      let tooLong = result?.tooLong ?? 0
      return FreeTimeSheet(
        title: DaySchedule.freeLabel(choice.gap.duration),
        subtitle: result.map { "\(span) · due \(format($0.start)) if you pick one" }
          ?? "This free time has passed.",
        rows: rows,
        footer: (tooLong > 0 ? "\(tooLong) longer reminders need more time. " : "")
          + "Nothing changes until you tap. Undo follows.",
        place: { place($0, in: choice.gap) })
    }

    private func place(_ task: OneTask, in gap: DateInterval) {
      let open = openTasks
      guard
        let result = GapFit.candidates(
          for: gap, reminders: open.map(gapReminder), now: presentation.now, calendar: cal),
        result.candidates.contains(where: { open[$0.index] === task })
      else {
        toast?.showNotice("This free time changed. Tap it again.")
        return
      }
      let time = result.start.plannerFormatted(
        date: .omitted, time: .shortened, runtime: presentation.runtime)
      do {
        try TaskActions.place(
          task, at: result.start, label: "“\(task.title)” due \(time)", context: context,
          toast: toast, reminders: reminders, ledger: ledger, runtime: presentation.runtime)
      } catch {
        toast?.showNotice("Couldn't move this reminder. " + error.localizedDescription)
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

  struct DayItems {
    var allDay: [OneEvent]
    var externalAllDay: [ExternalEvent]
    var timeline: [TimelineItem]
    var anytime: [OneTask]
  }

  struct DayPlan {
    var earlier: [TimelineItem]
    var planned: [TimelineItem]
    var free: [DateInterval]
    var marks: [TodayTimeline.Item]
    var rows: [TodayTimeline.Row]
    var range: DateInterval
  }

  @MainActor @Observable final class TimelineViewport {
    struct Continuation: Equatable {
      let first: AnyHashable
      let count: Int
    }

    private(set) var range: DateInterval?
    private(set) var continuation: Continuation?
    @ObservationIgnored private var upcoming: [AnyHashable] = []
    @ObservationIgnored private var upcomingIDs: Set<AnyHashable> = []
    @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored private var spans: [AnyHashable: DateInterval] = [:]
    @ObservationIgnored private var list = CGRect.zero
    @ObservationIgnored private var footer: CGFloat = 0
    @ObservationIgnored private var updatePending = false

    private var top: CGFloat { list.minY }
    private var bottom: CGFloat { list.maxY - footer }

    func setSpans(_ spans: [AnyHashable: DateInterval]) {
      self.spans = spans
      scheduleUpdate()
    }

    func setUpcoming(_ ids: [AnyHashable]) {
      upcoming = ids
      upcomingIDs = Set(ids)
      scheduleUpdate()
    }

    func setList(_ list: CGRect, footer: CGFloat) {
      self.list = list
      self.footer = footer
      scheduleUpdate()
    }

    func setFrame(_ frame: CGRect?, for id: AnyHashable) {
      let old = frames[id]
      frames[id] = frame
      let changesRange = spans[id] != nil && isVisible(old) != isVisible(frame)
      let changesContinuation =
        upcomingIDs.contains(id) && isAboveFooter(old) != isAboveFooter(frame)
      if changesRange || changesContinuation { scheduleUpdate() }
    }

    private func isVisible(_ frame: CGRect?) -> Bool {
      guard let frame else { return false }
      return TodayTimeline.intersects(minY: frame.minY, maxY: frame.maxY, top: top, bottom: bottom)
    }

    private func isAboveFooter(_ frame: CGRect?) -> Bool {
      guard let frame else { return false }
      return frame.maxY > top && frame.maxY <= bottom + 1
    }

    private func scheduleUpdate() {
      guard !updatePending else { return }
      updatePending = true
      DispatchQueue.main.async { [weak self] in self?.updateRange() }
    }

    private func updateRange() {
      updatePending = false
      let visible = frames.lazy.compactMap { id, frame -> TodayTimeline.Frame? in
        guard let span = self.spans[id] else { return nil }
        return TodayTimeline.Frame(span: span, minY: frame.minY, maxY: frame.maxY)
      }
      let next = TodayTimeline.viewport(visible, top: top, bottom: bottom)
      if next != range { range = next }
      let more = TodayTimeline.continuation(
        upcoming.map { id in frames[id].map { (minY: $0.minY, maxY: $0.maxY) } },
        top: top, bottom: bottom
      ).map { Continuation(first: upcoming[$0.index], count: $0.count) }
      if more != continuation { continuation = more }
    }
  }

  private struct TodayContinuation: View {
    let viewport: TimelineViewport
    let disabled: Bool
    let scrollTo: (AnyHashable) -> Void

    var body: some View {
      if let more = viewport.continuation {
        Button {
          scrollTo(more.first)
        } label: {
          HStack {
            Text("\(more.count) more today").lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.down")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(height: TodayTimeline.continuationHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .background(Color(.systemBackground))
        .disabled(disabled)
        .accessibilityIdentifier("today.more")
      }
    }
  }

  enum TimelineItem: Identifiable {
    case event(OneEvent, Date)
    case external(ExternalEvent)
    case due(OneTask)
    case alarm(OneAlarm, Date, Date?)
    case gap(DateInterval)
    case nowMarker(Date, DateInterval?)

    static let nowID = "now-line"

    var staysWhenClosed: Bool {
      !isPlanned
    }

    var id: AnyHashable {
      switch self {
      case .event(let e, let d): return [AnyHashable(e.persistentModelID), AnyHashable(d)]
      case .external(let e): return e.id
      case .due(let t): return ["due", AnyHashable(t.persistentModelID)]
      case .alarm(let a, let d, _): return [AnyHashable(a.persistentModelID), AnyHashable(d)]
      case .gap(let free): return ["gap", AnyHashable(free.start)]
      case .nowMarker: return Self.nowID
      }
    }

    var isPlanned: Bool {
      switch self {
      case .gap, .nowMarker: false
      default: true
      }
    }

    var span: DateInterval? {
      switch self {
      case .event(let event, let start):
        DateInterval(start: start, duration: max(0, event.duration))
      case .external(let event): DateInterval(start: event.start, end: max(event.start, event.end))
      case .gap(let free): free
      case .nowMarker(_, let gap): gap
      default: DateInterval(start: start, duration: 0)
      }
    }

    var dropAnchor: TimelineDropAnchor {
      switch self {
      case .event(let event, let start):
        TimelineDropAnchor(start: start, end: start.addingTimeInterval(event.duration))
      case .external(let event): TimelineDropAnchor(start: event.start, end: event.end)
      default: TimelineDropAnchor(start: start)
      }
    }

    func overlaps(_ date: Date, timing: TimelineDragTime) -> Bool {
      let length: TimeInterval
      switch self {
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
          ? date == start
          : date >= start && date < start.addingTimeInterval(length)
      }
      if length == 0 {
        return start >= date && start < date.addingTimeInterval(timing.duration)
      }
      return date < start.addingTimeInterval(length)
        && date.addingTimeInterval(timing.duration) > start
    }

    var title: String {
      switch self {
      case .event(let event, _): event.title
      case .external(let event): event.title
      case .due(let task): task.title
      case .alarm(let alarm, _, _): alarm.label.isEmpty ? "Alarm" : alarm.label
      case .gap, .nowMarker: ""
      }
    }

    var start: Date {
      switch self {
      case .event(_, let d): return d
      case .external(let e): return e.start
      case .due(let t): return t.due ?? .distantFuture
      case .alarm(_, let d, _): return d
      case .gap(let free): return free.start
      case .nowMarker(let d, _): return d
      }
    }
  }

  struct AgendaHeader: View {
    let title: String
    package var body: some View {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.secondaryLabel))
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 0, trailing: 20))
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

  /// Free time between items, with paired start times when the selected city is at work.
  struct FreeRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    private var secondaryTime = AgendaSecondaryTime()
    let free: DateInterval
    let open: () -> Void

    init(free: DateInterval, open: @escaping () -> Void) {
      self.free = free
      self.open = open
    }

    package var body: some View {
      let title = DaySchedule.freeLabel(free.duration)
      let start = free.start.plannerFormatted(
        date: .omitted, time: .shortened, runtime: presentation.runtime)
      let remote = secondaryTime.label(at: free.start)
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        if let remote {
          VStack(alignment: .leading, spacing: 0) {
            Text(start)
              .font(AgendaRowStyle.detail.monospacedDigit())
              .lineLimit(1)
              .minimumScaleFactor(0.75)
            AgendaSecondaryTime.line(remote)
          }
          .frame(width: AgendaRowStyle.timeWidth, alignment: .leading)
        }
        Text(title)
          .padding(.leading, remote == nil ? 68 : 0)
      }
      .font(AgendaRowStyle.detail)
      .foregroundStyle(Color(.secondaryLabel))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      .contentShape(Rectangle())
      .onTapGesture(perform: open)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        Text(verbatim: title + " from " + start + (remote.map { ", " + $0.spoken } ?? ""))
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Shows reminders that could fit here")
      .accessibilityIdentifier("today.freeRow")
    }
  }

#endif

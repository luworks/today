#if os(iOS)
  import TodayCore
  import TodayPlatform
  import TodayDesignSystem
  import One
  import TodayPlannerUI
  import SwiftUI
  import SwiftData

  /// Calendar tab, modeled on Apple Calendar: 2 Day (a time grid of two days, the default), Month (a compact grid with
  /// the selected day's events listed below) and Year (twelve mini months). The day view is the Today tab: tapping a day's header
  /// opens it there. One control row under the tab pills: the view switcher. Which calendars show is a Setting.
  /// System events open in Apple's own viewer; new events use Apple's own editor when Calendar access is on.
  package struct CalendarView: View {
    @Environment(PlannerPresentation.self) private var presentation
    package enum Mode: String, CaseIterable, Identifiable {
      // Raw values are stored (`today.last.calendarMode`) and name identifiers ("calendar.mode.twoday").
      case twoDay = "TwoDay"
      case month = "Month"
      case year = "Year"
      package var id: Self { self }
      package var title: String { self == .twoDay ? "2 Day" : rawValue }
    }

    private let actions: PlannerActions
    private let ledger: Ledger
    private let alarms: any AlarmService
    @Binding var day: Date
    /// 2 Day / Month / Year. Kept by `HomeView`, so switching tabs and back keeps the view.
    @Binding var mode: Mode
    let calendar: any CalendarService
    let onOpenTask: @MainActor (OneTask) -> Void
    let onOpenAlarm: @MainActor (OneAlarm) -> Void
    let onOpenDay: @MainActor (Date) -> Void
    /// The first and last day on screen (one month's start in Month), for the top bar's month label.
    let onVisibleDays: @MainActor (ClosedRange<Date>) -> Void

    @State private var opened: EventPresentation?
    /// Outlives Year itself, so Month ↔ Year reuses the computed marks.
    @State private var yearMarks = YearMarksCache()
    private enum EventPresentation: Identifiable {
      case local(OneEvent)
      case new(start: Date, end: Date)

      var id: String {
        switch self {
        case .local(let event): "l\(event.persistentModelID.hashValue)"
        case .new(let start, _): "n\(start.timeIntervalSince1970)"
        }
      }
    }

    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }

    @MainActor
    package init(
      day: Binding<Date>, mode: Binding<Mode>, calendar: any CalendarService,
      actions: PlannerActions, ledger: Ledger, alarms: any AlarmService,
      onOpenTask: @escaping @MainActor (OneTask) -> Void,
      onOpenAlarm: @escaping @MainActor (OneAlarm) -> Void,
      onOpenDay: @escaping @MainActor (Date) -> Void,
      onVisibleDays: @escaping @MainActor (ClosedRange<Date>) -> Void = { _ in }
    ) {
      _day = day
      _mode = mode
      self.calendar = calendar
      self.actions = actions
      self.ledger = ledger
      self.alarms = alarms
      self.onOpenTask = onOpenTask
      self.onOpenAlarm = onOpenAlarm
      self.onOpenDay = onOpenDay
      self.onVisibleDays = onVisibleDays
    }

    package var body: some View {
      VStack(spacing: 0) {
        controlRow
        Group {
          switch mode {
          case .twoDay:
            TwoDayView(
              calendar: calendar, day: $day, onVisibleDays: onVisibleDays, open: open, edit: edit,
              create: create, openDay: openDay)
          case .month:
            MonthView(
              calendar: calendar, day: $day, onVisibleDays: onVisibleDays, open: open, edit: edit,
              openDay: openDay)
          case .year:
            YearView(day: $day, calendar: calendar, marks: yearMarks, openDay: showMonth) { month in
              day = CalendarMath.landingDay(
                inMonthOf: month, today: presentation.now, calendar: cal)
              mode = .month
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .sheet(item: $opened) { item in
        switch item {
        case .local(let event):
          EventEditor(
            event: event, calendar: calendar, actions: actions, ledger: ledger, alarms: alarms,
            presentation: presentation)
        case .new(let start, let end):
          EventEditor(
            start: start, end: end, calendar: calendar, actions: actions, ledger: ledger,
            alarms: alarms, presentation: presentation)
        }
      }
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
    }

    /// System events open in Apple's editor (presented by UIKit, see `NativeEvents`); the rest in our editors.
    private func open(_ entry: CalEntry) {
      switch entry.source {
      case .system(let id):
        (calendar as? any NativeCalendarService)?.edit(
          identifier: id, start: entry.start, end: nil, fullOptions: false, onComplete: nil)
      case .task(let task): onOpenTask(task)
      case .alarm(let alarm): onOpenAlarm(alarm)
      case .local(let event): opened = .local(event)
      }
    }

    private func edit(_ entry: CalEntry) { open(entry) }

    /// A long-press on an empty slot of the 2 Day grid: Apple's editor when Calendar access is on, else ours, prefilled.
    private func create(start: Date, end: Date) {
      if calendar.usesNativeEditor, let native = calendar as? any NativeCalendarService {
        native.edit(identifier: nil, start: start, end: end, fullOptions: false, onComplete: nil)
      } else {
        opened = .new(start: start, end: end)
      }
    }

    /// Tapping a day that is already selected opens it in Today (the day view).
    private func openDay(_ date: Date) { onOpenDay(cal.startOfDay(for: date)) }

    /// Year day taps keep the exact date selected in Month and show its agenda below the grid.
    private func showMonth(_ date: Date) {
      day = cal.startOfDay(for: date)
      mode = .month
    }

    // MARK: One control row: the view switcher

    /// 2 Day / Month / Year as pills, the same style as the top tab pills (one size down), left-aligned. The month on
    /// screen is named once, in the top bar (`onVisibleDays`).
    private var controlRow: some View {
      HStack(spacing: PillStyle.spacing) {
        HStack(spacing: PillStyle.spacing) {
          ForEach(Mode.allCases) { item in
            PillButton(
              title: item.title, isSelected: item == mode,
              identifier: "calendar.mode.\(item.rawValue.lowercased())"
            ) {
              mode = item
            }
          }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
  }

  /// The Calendars list: Apple's own EKCalendarChooser (accounts, color dots, checkmarks) when access is on.
  package struct CalendarsSheet: View {
    let calendar: any CalendarService
    @Environment(\.colorScheme) private var colorScheme

    package init(calendar: any CalendarService) {
      self.calendar = calendar
    }

    @Environment(\.dismiss) private var dismiss

    package var body: some View {
      if calendar.isOn, let native = calendar as? any NativeCalendarService {
        NativeCalendarChooser(calendar: native)
          .ignoresSafeArea()
          .presentationDetents([.medium, .large])
      } else if calendar.isOn {
        NavigationStack {
          List(calendar.calendars(), id: \.id) { item in
            Toggle(
              isOn: Binding(
                get: { !calendar.hiddenCalendarIDs.contains(item.id) },
                set: { visible in
                  var selected = Set(calendar.calendars().map(\.id)).subtracting(
                    calendar.hiddenCalendarIDs)
                  if visible { selected.insert(item.id) } else { selected.remove(item.id) }
                  calendar.setVisibleCalendars(selected)
                })
            ) {
              Label {
                Text(item.title)
              } icon: {
                Circle().fill(item.color).frame(width: 12, height: 12)
              }
            }
          }
          .navigationTitle("Calendars")
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
      } else {
        NavigationStack {
          VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(
              .secondary)
            Text("Apple Calendar is off for Today").font(.headline)
            Text(
              "Turn it on to see your calendars here, choose which ones to show, and add events to them."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button {
              Task { await calendar.setEnabled(true) }
            } label: {
              Text("Turn On")
                .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
            }
            .buttonStyle(.borderedProminent)
          }
          .padding(32)
          .navigationTitle("Calendars")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
      }
    }
  }

  // MARK: - Month

  private struct MonthLocalSnapshot: Sendable {
    let start: Date
    let duration: TimeInterval
    let rule: RepeatRule?
    let allDay: Bool
    let title: String
    let tint: Int
  }

  @MainActor @Observable
  private final class MonthMarksCache {
    struct Page {
      let signature: Int
      let days: [Date: MonthDaySummary]
      let tints: [Color]
    }
    var pages: [Date: Page] = [:]
    @ObservationIgnored var loading: [Date: Int] = [:]
  }

  private struct MonthView: View {
    let calendar: any CalendarService
    @Environment(PlannerPresentation.self) private var presentation
    @Binding var day: Date
    var onVisibleDays: @MainActor (ClosedRange<Date>) -> Void
    var open: (CalEntry) -> Void
    var edit: (CalEntry) -> Void
    var openDay: (Date) -> Void

    @Query(sort: \OneEvent.start) private var events: [OneEvent]
    @Query private var tasks: [OneTask]
    @Query private var allAlarms: [OneAlarm]
    @AppStorage(SettingsKey.showAlarms) private var showsAlarms = true
    // Read so the grid updates when Settings changes the session calendar layout.
    @AppStorage(Preferences.firstWeekdayKey) private var firstWeekday = Preferences.firstWeekday
      .rawValue
    @AppStorage(Preferences.weekNumbersKey) private var showsWeekNumbers = Preferences.weekNumbers
    /// Months from the current one, the id of each page in the pager.
    @State private var pos: Int? = 0
    @State private var settled = 0
    @State private var clockRevision = 0
    @State private var marks = MonthMarksCache()
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 51
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }
    private var base: Date {
      CalendarMath.monthStart(offset: 0, from: presentation.now, calendar: cal)
    }
    private let range = -360...360

    private func month(_ offset: Int) -> Date {
      CalendarMath.monthStart(offset: offset, from: base, calendar: cal)
    }
    private var current: Int { settled }
    /// Alarms follow Settings → "Show alarms in the day", like the Today timeline.
    private var alarms: [OneAlarm] { showsAlarms ? allAlarms : [] }

    var body: some View {
      VStack(spacing: 0) {
        weekdayHeader
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
        pager
        DayAgendaList(
          calendar: calendar, day: day, events: events, tasks: tasks, alarms: alarms, open: open,
          edit: edit)
      }
      .onChange(of: day) { _, new in
        let target = CalendarMath.monthOffset(of: new, from: base, calendar: cal)
        if target != settled {
          settled = target
          withAnimation(.snappy) { pos = target }
        }
      }
      .onChange(of: current, initial: true) { _, new in onVisibleDays(month(new)...month(new)) }
      .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
        clockRevision += 1
      }
      .onAppear {
        let target = CalendarMath.monthOffset(of: day, from: base, calendar: cal)
        settled = target
        pos = target
      }
    }

    private var weekdayHeader: some View {
      let letters = CalendarMath.weekdayLetters(calendar: cal)
      return HStack(spacing: 0) {
        if showsWeekNumbers { Color.clear.frame(width: Self.weekNumberWidth, height: 1) }
        ForEach(0..<7, id: \.self) { i in
          Text(letters[i])
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 4)
      .accessibilityHidden(true)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    static let weekNumberWidth: CGFloat = 26

    /// Settings > Calendar > "Show week numbers": the week of the year at the start of each row of the visible month.
    private func weekNumberColumn(for offset: Int) -> some View {
      let weeks = CalendarMath.monthWeeks(of: month(offset), calendar: cal)
      return VStack(spacing: 0) {
        ForEach(weeks.indices, id: \.self) { w in
          let number = weeks[w].compactMap { $0 }.first.map {
            CalendarMath.weekNumber(of: $0, calendar: cal)
          }
          Text(number.map(String.init) ?? "")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: Self.weekNumberWidth, height: rowHeight)
            .accessibilityLabel(number.map { "Week \($0)" } ?? "")
            .accessibilityIdentifier("calendar.weekNumber")
        }
      }
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var signature: Int {
      _ = clockRevision
      var h = Hasher()
      h.combine(calendar.version)
      h.combine(cal.identifier)
      h.combine(cal.timeZone.identifier)
      h.combine(cal.firstWeekday)
      h.combine(cal.startOfDay(for: presentation.now))
      h.combine(showsAlarms)
      for e in events {
        h.combine(e.start)
        h.combine(e.durationMinutes)
        h.combine(e.repeatRule)
        h.combine(e.isAllDay)
        h.combine(e.title)
        h.combine(e.externalID)
        h.combine(e.calendarName)
      }
      for t in tasks {
        h.combine(t.title)
        h.combine(t.due)
        h.combine(t.durationMinutes)
        h.combine(t.isDone)
      }
      for a in alarms {
        h.combine(a.hour)
        h.combine(a.minute)
        h.combine(a.label)
        h.combine(a.weekdays)
        h.combine(a.isOn)
        if a.isOn && a.weekdays.isEmpty {
          h.combine(
            AlarmPlan.nextFire(
              hour: a.hour, minute: a.minute, weekdays: [], after: presentation.now, calendar: cal))
        }
      }
      return h.finalize()
    }

    private func load(_ start: Date, signature: Int) async {
      guard marks.pages[start]?.signature != signature, marks.loading[start] != signature,
        let interval = cal.dateInterval(of: .month, for: start)
      else { return }
      marks.loading[start] = signature
      defer { if marks.loading[start] == signature { marks.loading[start] = nil } }
      let c = cal
      let now = presentation.now
      let system = await calendar.loadEvents(
        in: interval, excluding: Set(events.compactMap(\.externalID)))
      guard !Task.isCancelled, self.signature == signature else { return }
      var tints: [Color] = []
      var indexes: [Color: Int] = [:]
      func tint(_ color: Color) -> Int {
        if let index = indexes[color] { return index }
        let index = tints.count
        tints.append(color)
        indexes[color] = index
        return index
      }
      let local: [MonthLocalSnapshot] = events.compactMap { e in
        guard !calendar.isHidden(externalID: e.externalID) else { return nil }
        return MonthLocalSnapshot(
          start: e.start, duration: e.duration, rule: e.repeats,
          allDay: e.isAllDay, title: e.title,
          tint: tint(calendar.calendar(forExternalID: e.externalID)?.color ?? .blue))
      }
      var entries: [MonthSummaryEntry] = system.map { e in
        MonthSummaryEntry(
          start: e.start, end: e.end, isAllDay: e.isAllDay,
          title: e.title, isAlarm: false, tintIndex: tint(e.color))
      }
      let accent = tint(.accentColor)
      for t in tasks where !t.isDone {
        guard let due = t.due, interval.contains(due),
          c.dateComponents([.hour, .minute], from: due) != DateComponents(hour: 0, minute: 0)
        else { continue }
        entries.append(
          MonthSummaryEntry(
            start: due, end: due.addingTimeInterval(TimeInterval(t.durationMinutes * 60)),
            isAllDay: false, title: t.title, isAlarm: false, tintIndex: accent))
      }
      let alarmSpecs = alarms.map(\.spec)
      let fixedEntries = entries
      let days = CalendarMath.monthWeeks(of: start, calendar: c).flatMap { $0 }.compactMap { $0 }
      let result = await Task.detached(priority: .userInitiated) {
        var all: [MonthSummaryEntry] = []
        for e in local {
          for occurrence in Recurrence.occurrences(
            start: e.start, duration: e.duration, rule: e.rule, in: interval, calendar: c)
          {
            all.append(
              MonthSummaryEntry(
                start: occurrence, end: occurrence.addingTimeInterval(e.duration),
                isAllDay: e.allDay, title: e.title, isAlarm: false, tintIndex: e.tint))
          }
        }
        all.append(contentsOf: fixedEntries)
        for ring in CalendarAlarms.occurrences(
          of: alarmSpecs, in: interval, now: now, calendar: c)
        {
          all.append(
            MonthSummaryEntry(
              start: ring.date, end: ring.date, isAllDay: false,
              title: CalendarAlarms.title(alarmSpecs[ring.index].label), isAlarm: true,
              tintIndex: accent))
        }
        return MonthSummary.summarize(days: days, entries: all, calendar: c)
      }.value
      guard !Task.isCancelled, self.signature == signature else { return }
      marks.pages[start] = MonthMarksCache.Page(
        signature: signature, days: Dictionary(uniqueKeysWithValues: result.map { ($0.day, $0) }),
        tints: tints)
    }

    private var pager: some View {
      let signature = signature
      let selectedDay = $day
      return ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 0) {
          ForEach(range, id: \.self) { offset in
            HStack(alignment: .top, spacing: 0) {
              if showsWeekNumbers { weekNumberColumn(for: offset) }
              MonthPage(
                month: month(offset), selected: day, rowHeight: rowHeight,
                page: marks.pages[month(offset)]
              ) { picked in
                if cal.isDate(picked, inSameDayAs: selectedDay.wrappedValue) {
                  openDay(picked)
                } else {
                  selectedDay.wrappedValue = cal.startOfDay(for: picked)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .containerRelativeFrame(.vertical, alignment: .top)
            .id(offset)
            .task(id: signature) { await load(month(offset), signature: signature) }
          }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(OneMonthPaging())
      .scrollPosition(id: $pos)
      .onScrollPhaseChange { _, phase in
        guard phase == .idle, let page = pos, page != settled else { return }
        settled = page
        day = CalendarMath.landingDay(
          inMonthOf: month(page), today: presentation.now, calendar: cal)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(
        height: CGFloat(CalendarMath.monthWeeks(of: month(current), calendar: cal).count)
          * rowHeight
      )
      .animation(.snappy, value: CalendarMath.monthWeeks(of: month(current), calendar: cal).count)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .accessibilityIdentifier("calendar.monthPager")
    }
  }

  /// One month of day cells: number, selection circle, and a small dot per event in the calendar's color.
  private struct MonthPage: View {
    @Environment(PlannerPresentation.self) private var presentation
    let month: Date
    let selected: Date
    let rowHeight: CGFloat
    let page: MonthMarksCache.Page?
    var onTap: (Date) -> Void
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }
    @AppStorage(Preferences.dimPastDaysKey) private var dimsPast = Preferences.dimPastDays
    @AppStorage(Preferences.firstWeekdayKey) private var firstWeekday = Preferences.firstWeekday
      .rawValue

    var body: some View {
      let weeks = CalendarMath.monthWeeks(of: month, calendar: cal)
      VStack(spacing: 0) {
        ForEach(weeks.indices, id: \.self) { w in
          HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
              if let d = weeks[w][i] {
                MonthCell(
                  day: d, number: cal.component(.day, from: d),
                  isToday: cal.isDate(d, inSameDayAs: presentation.now),
                  isSelected: cal.isDate(d, inSameDayAs: selected),
                  past: dimsPast && d < cal.startOfDay(for: presentation.now),
                  rowHeight: rowHeight, summary: page?.days[d], tints: page?.tints ?? [],
                  label: d.plannerFormatted(
                    date: .complete, time: .omitted, runtime: presentation.runtime),
                  identifier: CalendarIDs.day(d, calendar: cal), onTap: onTap
                ).equatable()
              } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: rowHeight)
              }
            }
          }
          .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        }
      }
    }

  }

  private struct MonthCell: View, Equatable {
    let day: Date
    let number: Int
    let isToday: Bool
    let isSelected: Bool
    let past: Bool
    let rowHeight: CGFloat
    let summary: MonthDaySummary?
    let tints: [Color]
    let label: String
    let identifier: String
    let onTap: (Date) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.day == rhs.day && lhs.number == rhs.number && lhs.isToday == rhs.isToday
        && lhs.isSelected == rhs.isSelected && lhs.past == rhs.past
        && lhs.rowHeight == rhs.rowHeight && lhs.summary == rhs.summary
        && lhs.tints == rhs.tints && lhs.label == rhs.label && lhs.identifier == rhs.identifier
    }

    private var speech: String {
      guard let summary else { return "" }
      if summary.eventCount == 0 && summary.alarmCount == 0 { return "no events" }
      var parts: [String] = []
      if summary.eventCount > 0 {
        parts.append("\(summary.eventCount) event\(summary.eventCount == 1 ? "" : "s")")
      }
      if summary.alarmCount > 0 {
        parts.append("\(summary.alarmCount) alarm\(summary.alarmCount == 1 ? "" : "s")")
      }
      return parts.joined(separator: ", ")
    }

    var body: some View {
      let fill: Color = isSelected ? (isToday ? .red : Color(.label)) : .clear
      let text: Color =
        isSelected
        ? (isToday ? .white : Color(.systemBackground))
        : (isToday ? .red : (past ? Color(.tertiaryLabel) : Color(.label)))
      return Button {
        onTap(day)
      } label: {
        VStack(spacing: 4) {
          Text("\(number)").font(.system(size: 17, weight: .medium)).foregroundStyle(text)
            .frame(width: 29, height: 29).background(fill, in: Circle())
          DayDots(
            colors: (summary?.tintIndices ?? []).compactMap {
              tints.indices.contains($0) ? tints[$0] : nil
            }
          )
          .frame(height: 5).opacity(past ? DayTint.past : 1)
        }
        .padding(.top, 4).frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .top)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(speech.isEmpty ? label : "\(label), \(speech)")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityIdentifier(identifier)
    }
  }

  /// Restrict even a high-velocity flick to the adjacent page.
  private struct OneMonthPaging: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
      let height = context.containerSize.height
      guard height > 0 else { return }
      let original = context.originalTarget.rect.minY
      let proposed = target.rect.minY
      let delta = proposed - original
      let direction: CGFloat =
        abs(delta) > height * 0.15
        ? (delta > 0 ? 1 : -1)
        : (abs(context.velocity.dy) > 100 ? (context.velocity.dy > 0 ? 1 : -1) : 0)
      target.rect.origin.y = max(
        0, min(context.contentSize.height - height, original + direction * height))
    }
  }

  /// Apple's compact-month marks: one dot per event, joined into a pill when there are several.
  private struct DayDots: View {
    let colors: [Color]

    var body: some View {
      if !colors.isEmpty {
        HStack(spacing: 0) {
          ForEach(Array(colors.enumerated()), id: \.offset) { _, c in c.frame(width: 5.5, height: 5)
          }
        }
        .clipShape(Capsule())
        .opacity(0.75)
        .accessibilityHidden(true)
      }
    }
  }

  /// The selected day's events under the month grid: all-day first, then by time, like Apple's list layout.
  private struct DayAgendaList: View {
    let calendar: any CalendarService
    @Environment(PlannerPresentation.self) private var presentation
    let day: Date
    let events: [OneEvent]
    let tasks: [OneTask]
    let alarms: [OneAlarm]
    var open: (CalEntry) -> Void
    var edit: (CalEntry) -> Void
    @State private var pendingDelete: CalEntry?
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }

    var body: some View {
      let interval =
        cal.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86400)
      let items = CalendarEntries.on(
        day,
        in: CalendarEntries.make(
          in: interval, events: events, tasks: tasks, alarms: alarms, calendarService: calendar,
          now: presentation.now, calendar: cal), calendar: cal)
      List {
        ForEach(items) { entry in
          AgendaRow(entry: entry, day: day)
            .onTapGesture { open(entry) }
            .entryActions(
              entry, pendingDelete: $pendingDelete, open: open, edit: edit, calendar: calendar
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .overlay {
        if items.isEmpty {
          Text("No Events")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 40)
            .allowsHitTesting(false)
        }
      }
      .animation(.snappy, value: items.map(\.id))
      .entryDeleteDialog($pendingDelete)
      .accessibilityIdentifier("calendar.dayList")
    }
  }

  /// One line of Apple's event list: calendar-colored bar, bold title, location, start and end time on the right.
  /// All-day events lead with a calendar glyph and say "all-day".
  private struct AgendaRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    let entry: CalEntry
    let day: Date
    @Environment(\.displayScale) private var scale
    @AppStorage(Preferences.dimPastDaysKey) private var dimsPast = Preferences.dimPastDays
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }

    var body: some View {
      let span = entry.span(on: day, calendar: cal)
      // Events that are over fade, like Apple's (Settings > Calendar > "Dim past days").
      let over =
        dimsPast
        && (span.allDay
          ? cal.startOfDay(for: day) < cal.startOfDay(for: presentation.now)
          : span.end <= presentation.now)
      let titleColor: Color = over ? Color(.secondaryLabel) : Color(.label)
      HStack(alignment: .top, spacing: 12) {
        if entry.isAlarm {
          // The bell Today's timeline uses for an alarm, in the accent color.
          Image(systemName: "alarm").font(.system(size: 17)).foregroundStyle(entry.color).frame(
            width: 22, height: 22)
        } else if entry.isTask {
          Image(systemName: "circle").font(.title3).foregroundStyle(entry.color).frame(
            width: 22, height: 22)
        } else if span.allDay {
          Image(systemName: "calendar")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(entry.color.contrastForeground(for: colorScheme))
            .frame(width: 28, height: 28)
            .background(entry.color, in: Circle())
        } else {
          RoundedRectangle(cornerRadius: 2).fill(entry.color).frame(width: 4).padding(.vertical, 1)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(span.allDay && !over ? Color(.label) : titleColor)
          if !entry.location.isEmpty {
            Label(entry.location, systemImage: "location.circle")
              .font(.subheadline)
              .foregroundStyle(over ? Color(.tertiaryLabel) : Color(.secondaryLabel))
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if span.allDay && !entry.isTask {
          Text("all-day").font(.body).foregroundStyle(over ? Color(.secondaryLabel) : Color(.label))
        } else {
          VStack(alignment: .trailing, spacing: 2) {
            Text(
              span.start.plannerFormatted(
                date: .omitted, time: .shortened, runtime: presentation.runtime)
            )
            .foregroundStyle(over ? Color(.secondaryLabel) : Color(.label))
            if !entry.isTask, !entry.isAlarm {
              Text(
                span.end.plannerFormatted(
                  date: .omitted, time: .shortened, runtime: presentation.runtime)
              ).foregroundStyle(Color(.tertiaryLabel))
            }
          }
          .font(.body.monospacedDigit())
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, span.allDay || entry.isTask || entry.isAlarm ? 10 : 9)
      .frame(minHeight: span.allDay || entry.isTask || entry.isAlarm ? 48 : 60, alignment: .top)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Color(.separator)).frame(height: 1 / scale).padding(.horizontal, 12)
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(plannerEntrySpeech(entry, runtime: presentation.runtime))
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier(entry.isAlarm ? "agenda.alarmRow" : "agenda.row")
    }
  }

  // MARK: - Year

  /// Each year's marks, kept by `CalendarView` so switching Month ↔ Year reuses them instead of recomputing.
  /// A year whose data changed keeps its last marks on screen until the new ones are ready.
  @MainActor
  @Observable
  private final class YearMarksCache {
    struct Year {
      var signature: Int
      var months: [YearMonth]
      /// Calendar colors, indexed by `YearBand.tint`.
      var tints: [Color]
    }
    var years: [Int: Year] = [:]
    /// Years being computed, with the data signature they are computed for.
    @ObservationIgnored var loading: [Int: Int] = [:]
  }

  private struct YearView: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Binding var day: Date
    let calendar: any CalendarService
    let marks: YearMarksCache
    var openDay: (Date) -> Void
    var pickMonth: (Date) -> Void
    @Query(sort: \OneEvent.start) private var events: [OneEvent]
    @Query private var tasks: [OneTask]
    @AppStorage(Preferences.firstWeekdayKey) private var firstWeekday = Preferences.firstWeekday
      .rawValue
    @AppStorage(YearMarkSettings.holidaysKey) private var holidaySetting = YearMarkSettings.auto
    @State private var showsKey = false

    var body: some View {
      let cal = Preferences.firstWeekdayChoice(presentation.defaults).calendar(
        base: presentation.calendar)
      let baseYear = cal.dateInterval(of: .year, for: presentation.now)?.start ?? presentation.now
      let signature = dataSignature(cal)
      let offset = { (date: Date) in
        cal.component(.year, from: date) - cal.component(.year, from: baseYear)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(-20...20, id: \.self) { y in
              let start = cal.date(byAdding: .year, value: y, to: baseYear) ?? baseYear
              yearSection(start, calendar: cal)
                .task(id: signature) { await load(start, signature: signature, calendar: cal) }
                .id(y)
            }
          }
          .padding(.bottom, 24)
        }
        .onAppear { proxy.scrollTo(offset(day), anchor: .top) }
        .onChange(of: day) { _, new in
          withAnimation(.snappy) { proxy.scrollTo(offset(new), anchor: .top) }
        }
      }
      .accessibilityIdentifier("calendar.year.scroll")
      .sheet(isPresented: $showsKey) { YearKeySheet() }
    }

    /// Everything the marks depend on. Computed once per redraw of the whole view, not per year.
    private func dataSignature(_ cal: Calendar) -> Int {
      var h = Hasher()
      h.combine(calendar.version)
      h.combine(holidaySetting)
      h.combine(presentation.locale.identifier)
      h.combine(cal.firstWeekday)
      for e in events {
        h.combine(e.start)
        h.combine(e.durationMinutes)
        h.combine(e.repeatRule)
        h.combine(e.isAllDay)
        h.combine(e.title)
        h.combine(e.calendarName)
        h.combine(e.externalID)
      }
      for t in tasks {
        h.combine(t.due)
        h.combine(t.repeatRule)
        h.combine(t.isDone)
        h.combine(t.title)
      }
      h.combine(cal.startOfDay(for: presentation.now))
      return h.finalize()
    }

    /// Computes a year's marks unless they are current. A year of Apple Calendar events is read off the main actor,
    /// Today's own events and reminders are merged here (they are model objects), and the per-day layout is built
    /// off the main actor. Drawing never waits: the grid shows at once and the marks follow.
    private func load(_ start: Date, signature: Int, calendar cal: Calendar) async {
      let year = cal.component(.year, from: start)
      #if DEBUG
        if YearCacheTrace.enabled { YearCacheTrace.request() }
      #endif
      if marks.years[year]?.signature == signature {
        #if DEBUG
          if YearCacheTrace.enabled { YearCacheTrace.hit() }
        #endif
        return
      }
      guard marks.loading[year] != signature,
        let end = cal.date(byAdding: .year, value: 1, to: start)
      else { return }
      #if DEBUG
        if YearCacheTrace.enabled, marks.years[year] != nil {
          YearCacheTrace.invalidated(cacheCount: marks.years.count)
        }
        let missStart = YearCacheTrace.enabled ? DispatchTime.now().uptimeNanoseconds : nil
      #endif
      marks.loading[year] = signature
      defer { if marks.loading[year] == signature { marks.loading[year] = nil } }
      let interval = DateInterval(start: start, end: end)
      let system = await calendar.loadEvents(
        in: interval, excluding: Set(events.compactMap(\.externalID)))
      guard !Task.isCancelled else { return }
      let (entries, tints) = yearEntries(in: interval, system: system, calendar: cal)
      let sets = YearMarkSettings.sets(holidaySetting, locale: presentation.locale)
      let today = presentation.now
      let months = await Task.detached(priority: .userInitiated) {
        YearLayout.months(
          yearStart: start, entries: entries, holidaySets: sets, today: today, calendar: cal)
      }.value
      // Kept even if the year scrolled away meanwhile: it is valid for this signature.
      marks.years[year] = YearMarksCache.Year(signature: signature, months: months, tints: tints)
      #if DEBUG
        if let missStart {
          YearCacheTrace.miss(year: year, start: missStart, cacheCount: marks.years.count)
        }
      #endif
    }

    /// The year's entries as plain values, with calendar colors replaced by indexes into `tints`.
    private func yearEntries(
      in interval: DateInterval, system: [ExternalEvent], calendar cal: Calendar
    ) -> (entries: [YearEntry], tints: [Color]) {
      var entries: [YearEntry] = []
      var tints: [Color] = []
      var tintIndex: [Color: Int] = [:]
      // Alarms are left out on purpose: a ring is not load. Everything else comes from the same merge as Week and Month.
      for entry in CalendarEntries.make(
        in: interval, events: events, tasks: tasks, calendarService: calendar,
        now: presentation.now, calendar: cal, forYearMarks: true, systemEvents: system)
      where !entry.isAlarm
        && (entry.isTask
          || !YearEventMarks.isBirthday(
            title: entry.title, calendarTitle: entry.calendarTitle,
            isBirthdayCalendar: entry.isBirthday))
      {
        let tint: Int
        if let known = tintIndex[entry.color] {
          tint = known
        } else {
          tint = tints.count
          tints.append(entry.color)
          tintIndex[entry.color] = tint
        }
        entries.append(
          YearEntry(
            id: entry.id, title: entry.title, start: entry.start, end: entry.end,
            isAllDay: entry.isAllDay, repeats: entry.repeats,
            isBackground: entry.isBackground
              || YearLoad.isBackgroundCalendar(
                isSubscription: false, isBirthday: false, title: entry.calendarTitle),
            isHoliday: entry.isHoliday, isTask: entry.isTask, tint: tint))
      }
      // A reminder that is still due counts on its due day, unless it has a time (then it is an entry above).
      let today = cal.startOfDay(for: presentation.now)
      for t in tasks where !t.isDone && t.repeatRule == nil {
        guard let due = t.due else { continue }
        let dueDay = cal.startOfDay(for: due)
        guard dueDay >= today, interval.contains(dueDay),
          let next = cal.date(byAdding: .day, value: 1, to: dueDay),
          cal.dateComponents([.hour, .minute], from: due) == DateComponents(hour: 0, minute: 0)
        else { continue }
        entries.append(
          YearEntry(
            id: "due\(t.persistentModelID.hashValue)", title: t.title, start: dueDay, end: next,
            isAllDay: true, isTask: true))
      }
      return (entries, tints)
    }

    private func yearSection(_ start: Date, calendar cal: Calendar) -> some View {
      let year = cal.component(.year, from: start)
      let isCurrent = cal.isDate(start, equalTo: presentation.now, toGranularity: .year)
      let loaded = marks.years[year]
      let months =
        loaded?.months ?? YearLayout.blank(yearStart: start, today: presentation.now, calendar: cal)
      return VStack(spacing: 14) {
        HStack {
          Text(start.plannerFormatted(.dateTime.year(), runtime: presentation.runtime))
            .font(.largeTitle.bold())
            .foregroundStyle(isCurrent ? Color.red : Color.primary)
            .accessibilityAddTraits(.isHeader)
            #if DEBUG
              .onAppear {
                if YearCacheTrace.enabled { YearCacheTrace.header(year: year, appeared: true) }
              }
              .onDisappear {
                if YearCacheTrace.enabled { YearCacheTrace.header(year: year, appeared: false) }
              }
            #endif
          Spacer()
          Button {
            PerformanceTrace.shared.beginPage("calendar.year.key")
            showsKey = true
          } label: {
            Image(systemName: "info.circle").font(.title3).foregroundStyle(.secondary)
              .frame(width: 44, height: 44).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("What the marks mean")
          .accessibilityIdentifier("calendar.year.key")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3),
          spacing: 12
        ) {
          ForEach(months, id: \.start) { month in
            MiniMonth(
              month: month, tints: loaded?.tints ?? [], isLoaded: loaded != nil, calendar: cal,
              openDay: openDay
            ) { pickMonth(month.start) }
          }
        }
        .padding(.horizontal, 20)
      }
      .dynamicTypeSize(...DynamicTypeSize.large)
    }
  }

  /// A small month for the Year view: holidays, calendar-color trip bands, quiet busy tints, and today
  /// as a red circle (see `YearLayout.swift` and docs/design/year-view.md). Month keeps Apple's dots.
  /// The day grid is one `Canvas`; each day is still its own VoiceOver button with the same label, value and identifier.
  private struct MiniMonth: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    let month: YearMonth
    /// Calendar colors for `month.bands`.
    let tints: [Color]
    /// False while the marks load: the grid is drawn, but VoiceOver and UI tests wait for the real values.
    let isLoaded: Bool
    let calendar: Calendar
    var openDay: (Date) -> Void
    var onTap: () -> Void

    private static let rowHeight: CGFloat = 16
    private static let rowSpacing: CGFloat = 6.5

    var body: some View {
      let isCurrent = month.today != nil
      VStack(alignment: .leading, spacing: 6) {
        Button(action: onTap) {
          Text(
            month.start.plannerFormatted(
              .dateTime.month(.abbreviated), runtime: presentation.runtime)
          )
          .font(.title3.bold())
          .foregroundStyle(isCurrent ? Color.red : Color.primary)
          .padding(.leading, 2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .accessibilityLabel(
          month.start.plannerFormatted(.dateTime.month(.wide).year(), runtime: presentation.runtime)
        )
        .accessibilityValue(month.summary)
        .accessibilityHint("Shows this month")
        .accessibilityIdentifier(CalendarIDs.month(month.start, calendar: calendar))
        GeometryReader { geometry in
          let width = geometry.size.width
          Canvas { context, size in draw(in: &context, size: size) }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
              if let index = dayIndex(at: location, width: width) { openDay(date(of: index)) }
            }
            .accessibilityChildren { dayElements }
        }
        .frame(height: Self.rowHeight * 6 + Self.rowSpacing * 5)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(!isLoaded)
    }

    private func date(of day: Int) -> Date {
      calendar.date(byAdding: .day, value: day, to: month.start) ?? month.start
    }

    /// The day under a tap: columns are a seventh of the width; a row owns half the gap on each side.
    private func dayIndex(at point: CGPoint, width: CGFloat) -> Int? {
      guard width > 0, point.x >= 0, point.y >= -Self.rowSpacing / 2 else { return nil }
      let pitch = Self.rowHeight + Self.rowSpacing
      return month.day(
        week: Int((point.y + Self.rowSpacing / 2) / pitch), column: Int(point.x / (width / 7)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
      let column = size.width / 7
      let pitch = Self.rowHeight + Self.rowSpacing
      // Bands sit behind the numbers. Later events come first, so the earliest owns the cells it shares,
      // and each band covers the one under it with the background so overlaps never darken.
      for band in month.bands {
        let rect = CGRect(
          x: column * CGFloat(band.firstColumn), y: CGFloat(band.week) * pitch,
          width: column * CGFloat(band.lastColumn - band.firstColumn + 1), height: Self.rowHeight)
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(shape, with: .color(Color(.systemBackground)))
        let tint = tints.indices.contains(band.tint) ? tints[band.tint] : Color.blue
        context.fill(shape, with: .color(EventTint.fill(tint)))
      }
      for (index, day) in month.days.enumerated() {
        let cell = month.cell(of: index)
        let center = CGPoint(
          x: column * (CGFloat(cell.column) + 0.5),
          y: CGFloat(cell.week) * pitch + Self.rowHeight / 2)
        let isToday = index == month.today
        if isToday {
          context.fill(
            Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
            with: .color(.red))
        } else if day.showsBusy {
          context.fill(
            Path(
              roundedRect: CGRect(x: center.x - 9, y: center.y - 8, width: 18, height: 16),
              cornerRadius: 4),
            with: .color(DayTint.busyDay))
        }
        context.draw(
          Text("\(index + 1)")
            .font(.system(size: 10.5, weight: day.isHoliday ? .bold : .semibold).monospacedDigit())
            .foregroundStyle(
              isToday
                ? Color.red.contrastForeground(for: colorScheme)
                : (day.isHoliday ? DayTint.holiday : Color.primary)),
          at: center)
      }
    }

    /// One VoiceOver button per day, laid out over the same grid the Canvas draws.
    private var dayElements: some View {
      VStack(spacing: Self.rowSpacing) {
        ForEach(0..<6, id: \.self) { week in
          HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
              if let index = month.day(week: week, column: column) {
                let dayDate = date(of: index)
                Color.clear
                  .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
                  .accessibilityElement()
                  .accessibilityLabel(
                    dayDate.plannerFormatted(
                      date: .complete, time: .omitted, runtime: presentation.runtime)
                  )
                  .accessibilityValue(month.days[index].notes.joined(separator: "; "))
                  .accessibilityHint("Shows this day and its events in Month")
                  .accessibilityAddTraits(.isButton)
                  .accessibilityIdentifier("year.\(CalendarIDs.day(dayDate, calendar: calendar))")
                  .accessibilityAction { openDay(dayDate) }
              } else {
                Color.clear
                  .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - 2 Day

  /// The 2 Day grid's sideways scroll, in day columns from today (1.5 = halfway between tomorrow and the day after as
  /// the first column). Observed apart from the grid, so only the header and the all-day row redraw while the finger moves.
  @Observable private final class DayScroll {
    var columns: CGFloat = 0
  }

  /// Two days side by side on a time grid, like Apple Calendar's multi-day view on iPhone: swipe sideways to move one
  /// day. The first column is the selected day: today when Calendar opens, the picked day when coming from Month or Year.
  /// Events are tinted blocks in their calendar's color; reminders with a time and alarms are one-line chips.
  /// Nothing on the grid moves by drag.
  private struct TwoDayView: View {
    static let columns = 2
    let calendar: any CalendarService
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Binding var day: Date
    var onVisibleDays: @MainActor (ClosedRange<Date>) -> Void
    var open: (CalEntry) -> Void
    var edit: (CalEntry) -> Void
    var create: (Date, Date) -> Void
    var openDay: (Date) -> Void

    @Query(sort: \OneEvent.start) private var events: [OneEvent]
    @Query private var tasks: [OneTask]
    @Query private var allAlarms: [OneAlarm]
    @AppStorage(SettingsKey.showAlarms) private var showsAlarms = true
    @AppStorage(Preferences.dimPastDaysKey) private var dimsPast = Preferences.dimPastDays
    @AppStorage(Preferences.firstWeekdayKey) private var firstWeekday = Preferences.firstWeekday
      .rawValue
    @AppStorage(Preferences.weekNumbersKey) private var showsWeekNumbers = Preferences.weekNumbers
    @AppStorage(Preferences.compressEmptyHoursKey) private var compressEmptyHours =
      Preferences.compressEmptyHours
    @State private var expandedGaps: Set<CalendarGapLayout.Interval> = []
    /// Days from today of the first column.
    @State private var pos: Int? = 0
    @State private var scroll = DayScroll()
    /// Points per hour; pinch the grid to change it.
    @State private var hourHeight: CGFloat = 48
    /// The hour height when the current pinch started.
    @State private var pinchStart: CGFloat?
    @State private var pendingDelete: CalEntry?
    private let gutter: CGFloat = 52
    private let range = -800...800
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }
    private var today: Date { cal.startOfDay(for: presentation.now) }
    private var first: Int { pos ?? 0 }
    private var alarms: [OneAlarm] { showsAlarms ? allAlarms : [] }

    private func date(_ offset: Int) -> Date {
      cal.date(byAdding: .day, value: offset, to: today) ?? today
    }
    private func offset(of date: Date) -> Int {
      cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
    }

    var body: some View {
      // The all-day items around the visible days, read once per day moved, not per frame of the swipe.
      let near = DateInterval(start: date(first - 2), end: date(first + Self.columns + 2))
      let allDay = CalendarEntries.make(
        in: near, events: events, tasks: tasks, alarms: alarms, calendarService: calendar,
        now: presentation.now, calendar: cal
      ).filter(\.isAllDay)
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          weekNumber
          DayStrip(scroll: scroll) { header(date($0)) }
        }
        .frame(height: 52)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        AllDayRow(
          scroll: scroll, items: allDay, today: today, gutter: gutter, calendar: calendar,
          pendingDelete: $pendingDelete, open: open, edit: edit)
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
        grid
      }
      .entryDeleteDialog($pendingDelete)
      .onChange(of: day) { _, new in
        let target = offset(of: new)
        if target != pos { withAnimation(.snappy) { pos = target } }
      }
      .onChange(of: pos) { _, new in
        guard let new, offset(of: day) != new else { return }
        day = date(new)
      }
      .onChange(of: visibleDays, initial: true) { _, new in onVisibleDays(new) }
      .onAppear {
        pos = offset(of: day)
        scroll.columns = CGFloat(offset(of: day))
      }
    }

    private var visibleDays: ClosedRange<Date> { date(first)...date(first + Self.columns - 1) }

    // MARK: Header

    /// Settings > Calendar > "Show week numbers": "W43", the week of the first column, over the hour labels.
    private var weekNumber: some View {
      let number = CalendarMath.weekNumber(of: date(first), calendar: cal)
      return Text(showsWeekNumbers ? "W\(number)" : "")
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: gutter)
        .accessibilityLabel("Week \(number)")
        .accessibilityHidden(!showsWeekNumbers)
        .accessibilityIdentifier("calendar.weekNumber")
    }

    /// Weekday letter over the date; today in a red circle, days that are over dimmed. Tap opens the day in Today.
    private func header(_ d: Date) -> some View {
      let isToday = cal.isDate(d, inSameDayAs: presentation.now)
      let past = dimsPast && d < today
      let letter = cal.veryShortStandaloneWeekdaySymbols[cal.component(.weekday, from: d) - 1]
      return Button {
        openDay(d)
      } label: {
        VStack(spacing: 2) {
          Text(letter)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(past ? Color(.tertiaryLabel) : Color(.label))
          Text("\(cal.component(.day, from: d))")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(
              isToday
                ? Color.red.contrastForeground(for: colorScheme)
                : (past ? Color(.tertiaryLabel) : Color(.label))
            )
            .frame(width: 29, height: 29)
            .background(isToday ? Color.red : Color.clear, in: Circle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        d.plannerFormatted(date: .complete, time: .omitted, runtime: presentation.runtime)
      )
      .accessibilityHint("Opens the day")
    }

    // MARK: Time grid

    // A single axis shared by every visible column and the hour gutter.
    private var gapLayout: CalendarGapLayout {
      let left = Int(scroll.columns.rounded(.down))
      let right = Int((scroll.columns + CGFloat(Self.columns)).rounded(.up))
      let days = (left..<max(left + 1, right)).map { offset in
        let day = date(offset)
        let interval =
          cal.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86400)
        let entries = CalendarEntries.make(
          in: interval, events: events, tasks: tasks, alarms: alarms, calendarService: calendar,
          now: presentation.now, calendar: cal
        ).filter { !$0.isAllDay }
        let spans = entries.filter { !$0.isTask && !$0.isAlarm }.map { entry in
          let span = CalendarDayAxis.span(
            start: entry.start, end: entry.end, in: interval, calendar: cal)
          return CalendarGapLayout.Interval(start: span.start, end: span.end)
        }
        let marks = entries.filter { ($0.isTask || $0.isAlarm) && interval.contains($0.start) }
          .map { CalendarDayAxis.minute($0.start, calendar: cal) }
        return CalendarGapLayout.Day(intervals: spans, marks: marks)
      }
      return CalendarGapLayout(
        days: compressEmptyHours ? days : [], pointsPerHour: Double(hourHeight),
        minimumGapMinutes: 120, compressedGapHeight: 44, expandedGaps: expandedGaps)
    }

    /// Hour labels stay put on the left; the day columns scroll sideways and snap to a day, one day per swipe.
    private var grid: some View {
      let axis = gapLayout
      return ScrollView {
        HStack(alignment: .top, spacing: 0) {
          hourLabels(axis)
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
              ForEach(range, id: \.self) { o in
                DayColumn(
                  calendar: calendar, day: date(o), fromToday: o, events: events, tasks: tasks,
                  alarms: alarms, hourHeight: hourHeight, axis: axis, expandedGaps: $expandedGaps,
                  pendingDelete: $pendingDelete,
                  open: open, edit: edit, create: create
                )
                .containerRelativeFrame(.horizontal, count: Self.columns, span: 1, spacing: 0)
                .id(o)
              }
            }
            .scrollTargetLayout()
          }
          .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
          .scrollPosition(id: $pos, anchor: .leading)
          .onScrollGeometryChange(for: CGFloat.self) { geo in
            let column = geo.containerSize.width / CGFloat(Self.columns)
            return column > 0 ? geo.contentOffset.x / column : 0
          } action: { _, x in
            scroll.columns = CGFloat(range.lowerBound) + x
          }
          .frame(height: CGFloat(axis.height))
          .overlay(alignment: .top) { gapBands(axis) }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
      }
      .scrollIndicators(.hidden)
      // Two fingers zoom the hours; one finger still scrolls, swipes days, taps and long-presses.
      .simultaneousGesture(
        MagnifyGesture(minimumScaleDelta: 0.02)
          .onChanged { value in
            let start = pinchStart ?? hourHeight
            pinchStart = start
            hourHeight = CGFloat(
              CalendarLayout.zoomedHourHeight(Double(start), scale: Double(value.magnification)))
          }
          .onEnded { _ in pinchStart = nil }
      )
      .accessibilityIdentifier("calendar.dayGrid")
    }

    private func gapBands(_ axis: CalendarGapLayout) -> some View {
      GeometryReader { geometry in
        ForEach(axis.gaps, id: \.self) { gap in
          if !expandedGaps.contains(gap) {
            Button {
              expandedGaps.insert(gap)
            } label: {
              Text(CalendarGapPresentation.rangeLabel(start: gap.start, end: gap.end))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: geometry.size.width, height: 44)
                .background(Color(.secondarySystemBackground).opacity(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(
              x: geometry.size.width / 2,
              y: CGFloat(CalendarGapPresentation.centerY(axis: axis, gap: gap))
            )
            .accessibilityIdentifier("calendar.gapBand.\(Int(gap.start / 60)).\(Int(gap.end / 60))")
          }
        }
      }
    }

    private func hourLabels(_ axis: CalendarGapLayout) -> some View {
      ZStack(alignment: .topLeading) {
        ForEach(0..<24, id: \.self) { h in
          if !axis.gaps.contains(where: {
            !expandedGaps.contains($0) && Double(h * 60) >= $0.start && Double(h * 60) < $0.end
          }) {
            Text(hourLabel(h))
              .font(.system(size: 10).monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: gutter - 4, alignment: .trailing)
              .offset(y: CGFloat(axis.y(forMinute: Double(h * 60))) - 6)
              .accessibilityIdentifier("calendar.hour.\(h)")
          }
        }
        ForEach(axis.gaps, id: \.self) { gap in
          let expanded = expandedGaps.contains(gap)
          Button {
            if expanded { expandedGaps.remove(gap) } else { expandedGaps.insert(gap) }
          } label: {
            Image(systemName: expanded ? "chevron.compact.up" : "arrow.up.and.down")
              .foregroundStyle(.secondary)
              .frame(width: gutter, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .offset(y: CGFloat(axis.y(forMinute: gap.start)))
          .accessibilityLabel("Empty hours \(Int(gap.start / 60)) to \(Int(gap.end / 60))")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
          .accessibilityIdentifier("calendar.gap.\(Int(gap.start / 60)).\(Int(gap.end / 60))")
        }
        if (1 - Self.columns...0).contains(first) {
          TimelineView(.everyMinute) { _ in nowLabel(axis) }
        }
      }
      .frame(width: gutter, height: CGFloat(axis.height), alignment: .topLeading)
    }

    private func nowLabel(_ axis: CalendarGapLayout) -> some View {
      let y = CGFloat(axis.y(forMinute: CalendarDayAxis.minute(presentation.now, calendar: cal)))
      return Text(
        presentation.now.plannerFormatted(
          date: .omitted, time: .shortened, runtime: presentation.runtime)
      )
      .font(.system(size: 10, weight: .semibold).monospacedDigit())
      .foregroundStyle(Color.red.contrastForeground(for: colorScheme))
      .padding(.horizontal, 4)
      .frame(height: 16)
      .background(Color.red, in: Capsule())
      .fixedSize()
      .frame(width: gutter, alignment: .trailing)
      .offset(y: y - 8)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }

    private func hourLabel(_ h: Int) -> String {
      h == 0
        ? ""
        : (cal.date(bySettingHour: h, minute: 0, second: 0, of: presentation.now)
          ?? presentation.now)
          .plannerFormatted(
            .dateTime.hour(.defaultDigits(amPM: .abbreviated)), runtime: presentation.runtime)
    }
  }

  /// Day cells that follow the 2 Day grid's sideways scroll: the visible days and one on either side, clipped.
  private struct DayStrip<Cell: View>: View {
    let scroll: DayScroll
    let cell: (Int) -> Cell

    var body: some View {
      GeometryReader { geo in
        let width = geo.size.width / CGFloat(TwoDayView.columns)
        let at = scroll.columns
        let first = Int(at.rounded(.down))
        ForEach(first - 1...first + TwoDayView.columns, id: \.self) { o in
          cell(o)
            .frame(width: width, height: geo.size.height)
            .offset(x: (CGFloat(o) - at) * width)
        }
      }
      .clipped()
    }
  }

  /// The 2 Day all-day row: banners across the days they cover, following the grid's sideways scroll.
  private struct AllDayRow: View {
    let scroll: DayScroll
    /// All-day items of the days around the visible ones.
    let items: [CalEntry]
    let today: Date
    let gutter: CGFloat
    let calendar: any CalendarService
    @Binding var pendingDelete: CalEntry?
    var open: (CalEntry) -> Void
    var edit: (CalEntry) -> Void
    @Environment(PlannerPresentation.self) private var presentation
    private let rowHeight: CGFloat = 21
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }

    var body: some View {
      // Days from today, inclusive. Lanes are laid out over all the nearby days, so the row keeps its height mid-swipe.
      let spans: [(start: Int, end: Int)] = items.map { e in
        let first =
          cal.dateComponents([.day], from: today, to: cal.startOfDay(for: e.start)).day ?? 0
        let last =
          cal.dateComponents(
            [.day], from: today, to: cal.startOfDay(for: e.end.addingTimeInterval(-1))
          ).day ?? 0
        return (first, max(first, last))
      }
      let lanes = CalendarLayout.lanes(for: spans)
      let laneCount = min((lanes.max() ?? 0) + 1, 4)
      if !items.isEmpty {
        HStack(alignment: .top, spacing: 0) {
          Text("all-day")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: gutter - 4, height: rowHeight, alignment: .trailing)
            .padding(.trailing, 4)
          GeometryReader { geo in
            let colW = geo.size.width / CGFloat(TwoDayView.columns)
            let at = scroll.columns
            ForEach(Array(items.enumerated()), id: \.offset) { i, e in
              if lanes[i] < laneCount {
                Text(e.title)
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(EventTint.text(e.color))
                  .lineLimit(1)
                  .padding(.horizontal, 4)
                  .frame(
                    width: CGFloat(spans[i].end - spans[i].start + 1) * colW - 2,
                    height: rowHeight - 2, alignment: .leading
                  )
                  .background(EventTint.fill(e.color), in: RoundedRectangle(cornerRadius: 5))
                  .offset(
                    x: (CGFloat(spans[i].start) - at) * colW + 1,
                    y: CGFloat(lanes[i]) * rowHeight
                  )
                  .onTapGesture { open(e) }
                  .entryActions(
                    e, pendingDelete: $pendingDelete, open: open, edit: edit, swipes: false,
                    calendar: calendar
                  )
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(plannerEntrySpeech(e, runtime: presentation.runtime))
                  .accessibilityAddTraits(.isButton)
              }
            }
          }
          .frame(height: CGFloat(laneCount) * rowHeight)
          .clipped()
        }
        .padding(.bottom, 4)
      }
    }
  }

  /// One day of the 2 Day grid: hour lines, events as blocks (staggered where they overlap), reminders and alarm rings
  /// as one-line chips at their time, the now line, and a long-press on empty space that places a new event.
  private struct DayColumn: View {
    let calendar: any CalendarService
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    /// Start of the day.
    let day: Date
    /// Days from today: 0 is today.
    let fromToday: Int
    let events: [OneEvent]
    let tasks: [OneTask]
    let alarms: [OneAlarm]
    let hourHeight: CGFloat
    let axis: CalendarGapLayout
    @Binding var expandedGaps: Set<CalendarGapLayout.Interval>
    @Binding var pendingDelete: CalEntry?
    var open: (CalEntry) -> Void
    var edit: (CalEntry) -> Void
    var create: (Date, Date) -> Void
    /// The start minute of the new event being placed by a long-press.
    @State private var draft: Int?
    @AppStorage(Preferences.dimPastDaysKey) private var dimsPast = Preferences.dimPastDays
    private var cal: Calendar {
      Preferences.firstWeekdayChoice(presentation.defaults).calendar(base: presentation.calendar)
    }

    var body: some View {
      let interval =
        cal.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86400)
      let entries = CalendarEntries.make(
        in: interval, events: events, tasks: tasks, alarms: alarms, calendarService: calendar,
        now: presentation.now, calendar: cal)
      let placed = place(entries.filter { !$0.isAllDay && !$0.isAlarm && !$0.isTask }, in: interval)
      // Reminders and alarms are a moment, not a span: a chip at their time, never a box of made-up length.
      let marks = entries.filter { ($0.isTask || $0.isAlarm) && interval.contains($0.start) }
        .sorted { $0.start < $1.start }
      let past = dimsPast && fromToday < 0
      GeometryReader { geo in
        let width = geo.size.width
        let layout = CalendarLayout.timedDay(
          blocks: placed.map {
            let start = Double($0.startMinute)
            let end = Double($0.startMinute + $0.lengthMinutes)
            let height = max(18, axis.height(from: start, to: end) - 1)
            return (y: axis.y(forMinute: start), height: height)
          },
          marks: marks.map {
            axis.y(forMinute: CalendarDayAxis.minute($0.start, calendar: cal))
          },
          columnWidth: Double(width), chipHeight: Double(Self.chipHeight),
          foldAfter: max(24, Double(hourHeight) * 0.75))
        let blockRects = layout.blocks.map { CGRect($0) }
        let markRects = layout.marks.map { $0.map { CGRect($0) } }
        let shown = marks.indices.filter { markRects[$0] != nil }
        // Deeper (later) events are drawn over the ones they overlap, as in Apple Calendar.
        let drawOrder = placed.indices.sorted { layout.depths[$0] < layout.depths[$1] }
        ZStack(alignment: .topLeading) {
          hourLines
          // Bottom layer: long-press an empty slot to make an event there. Blocks and chips keep their own taps and menus.
          pressLayer(blockRects + markRects.compactMap { $0 }, width: width)
          ForEach(drawOrder, id: \.self) { i in
            let r = blockRects[i]
            block(
              placed[i].entry, width: r.width, height: r.height, lines: placed[i].titleLines,
              outlined: layout.depths[i] > 0
            )
            .opacity(past ? DayTint.past : 1)
            .offset(x: r.minX, y: r.minY)
          }
          ForEach(shown, id: \.self) { i in
            if let r = markRects[i] {
              chip(marks[i], more: layout.folded[i].map { marks[$0] })
                .opacity(past ? DayTint.past : 1)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
          }
          // The now line: strong on today, faint across the other days on screen with it.
          if abs(fromToday) < TwoDayView.columns {
            TimelineView(.everyMinute) { _ in nowLine(strong: fromToday == 0) }
          }
          if let draft { draftBlock(draft, width: width) }
        }
        .frame(width: width, height: CGFloat(axis.height), alignment: .topLeading)
      }
      .frame(height: CGFloat(axis.height))
    }

    private var hourLines: some View {
      ZStack(alignment: .topLeading) {
        ForEach(0..<24, id: \.self) { h in
          if !axis.gaps.contains(where: {
            !expandedGaps.contains($0) && Double(h * 60) > $0.start && Double(h * 60) < $0.end
          }) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
              .offset(y: CGFloat(axis.y(forMinute: Double(h * 60))))
          }
        }
      }
      .frame(height: CGFloat(axis.height), alignment: .topLeading)
      .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }

    private func nowLine(strong: Bool) -> some View {
      let y = CGFloat(axis.y(forMinute: CalendarDayAxis.minute(presentation.now, calendar: cal)))
      return Rectangle()
        .fill(strong ? Color.red : Color.red.opacity(0.35))
        .frame(height: strong ? 1.5 : 1)
        .offset(y: strong ? y - 0.5 : y)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    struct Placed {
      let entry: CalEntry
      let startMinute: CGFloat
      let lengthMinutes: CGFloat
      func y(_ hourHeight: CGFloat) -> CGFloat { startMinute / 60 * hourHeight }
      func height(_ hourHeight: CGFloat) -> CGFloat { lengthMinutes / 60 * hourHeight - 1 }
      /// Blocks of 45 minutes or longer let the title wrap onto up to 3 lines; shorter ones keep one line.
      var titleLines: Int { lengthMinutes >= 45 ? 3 : 1 }
    }

    /// Timed events on the day, clipped to it; `CalendarLayout.timedDay` decides where they go.
    private func place(_ timed: [CalEntry], in interval: DateInterval) -> [Placed] {
      let items = timed.filter {
        $0.start < interval.end && max($0.end, $0.start.addingTimeInterval(900)) > interval.start
      }
      .sorted { $0.start < $1.start }
      let spans = items.map { e -> (start: Double, end: Double) in
        CalendarDayAxis.span(start: e.start, end: e.end, in: interval, calendar: cal)
      }
      return items.indices.map { i in
        Placed(
          entry: items[i],
          startMinute: CGFloat(spans[i].start),
          lengthMinutes: CGFloat(spans[i].end - spans[i].start))
      }
    }

    static let chipHeight: CGFloat = 18

    /// A reminder or alarm ring on the grid: one line at its time (circle or alarm symbol and the title), on the page's
    /// background so it reads over the hour lines. Tap opens it, long-press has its usual menu; nothing is dragged.
    /// `more` are the items folded under it on a crowded hour, behind a "+N" menu.
    private func chip(_ e: CalEntry, more: [CalEntry]) -> some View {
      HStack(spacing: 3) {
        HStack(spacing: 3) {
          if e.isAlarm {
            Image(systemName: "alarm").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(e.color)
          } else {
            Circle().strokeBorder(e.color, lineWidth: 1.2).frame(width: 9, height: 9)
          }
          Text(e.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { open(e) }
        .entryActions(
          e, pendingDelete: $pendingDelete, open: open, edit: edit, swipes: false,
          calendar: calendar
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plannerEntrySpeech(e, runtime: presentation.runtime))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(e.isAlarm ? "calendar.alarmMarker" : "calendar.reminderChip")
        if !more.isEmpty { moreMenu(more) }
      }
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 3))
    }

    /// "+N": the items folded on a crowded hour. Picking one opens it.
    private func moreMenu(_ more: [CalEntry]) -> some View {
      Menu {
        ForEach(more) { e in
          let time = e.start.plannerFormatted(
            date: .omitted, time: .shortened, runtime: presentation.runtime)
          Button {
            open(e)
          } label: {
            Label("\(time)  \(e.title)", systemImage: e.isAlarm ? "alarm" : "circle")
          }
        }
      } label: {
        Text("+\(more.count)")
          .font(.system(size: 10, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .frame(maxHeight: .infinity)
          .background(Color(.tertiarySystemFill), in: Capsule())
      }
      .accessibilityLabel("\(more.count) more")
      .accessibilityIdentifier("calendar.moreMarks")
    }

    /// An event on the grid: a color stripe and the title. A staggered block (drawn over an earlier one) gets a thin
    /// outline in the page's color so its edge stays visible.
    private func block(
      _ e: CalEntry, width: CGFloat, height: CGFloat, lines: Int, outlined: Bool
    ) -> some View {
      HStack(spacing: 0) {
        Rectangle().fill(e.color).frame(width: min(3, width))
        if width >= 12 {
          Text(e.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(EventTint.text(e.color))
            .lineLimit(lines)
            .lineSpacing(-1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 3)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
      .frame(width: width, height: height, alignment: .leading)
      .clipped()
      .background(EventTint.fill(e.color))
      // The tint is see-through; a staggered block hides the one under it.
      .background(outlined ? Color(.systemBackground) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay {
        if outlined {
          RoundedRectangle(cornerRadius: 4).strokeBorder(Color(.systemBackground), lineWidth: 1.5)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { open(e) }
      .entryActions(
        e, pendingDelete: $pendingDelete, open: open, edit: edit, swipes: false,
        calendar: calendar
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(plannerEntrySpeech(e, runtime: presentation.runtime))
      .accessibilityAddTraits(.isButton)
    }

    /// Long-press an empty slot: a one-hour placeholder appears there (snapped to 15 minutes) and follows the finger;
    /// releasing opens the new-event editor for that time, like Apple Calendar's day grids. A UIKit long-press (see
    /// `SlotPressView`): moving before it is recognized fails it, so scrolling and day swipes are untouched; once it is
    /// recognized, the scroll views don't take the finger.
    private func pressLayer(_ blocks: [CGRect], width: CGFloat) -> some View {
      func minute(_ point: CGPoint) -> Int {
        let minute = axis.minute(atY: Double(point.y))
        return min(1425, max(0, Int((minute / 15).rounded()) * 15))
      }
      return SlotPressView { point in
        // A press on an event or alarm is theirs (its menu); only empty space makes an event.
        !blocks.contains { $0.contains(point) }
          && !axis.gaps.contains { gap in
            let y = Double(point.y)
            return axis.height(from: gap.start, to: gap.end)
              < (gap.end - gap.start) / 60 * Double(hourHeight)
              && y >= axis.y(forMinute: gap.start) && y < axis.y(forMinute: gap.end)
          }
      } changed: { point in
        draft = minute(point)
      } ended: { point in
        draft = nil
        guard let point, let start = cal.date(byAdding: .minute, value: minute(point), to: day)
        else { return }
        create(start, start.addingTimeInterval(3600))
      }
      .frame(width: width, height: CGFloat(axis.height))
      .sensoryFeedback(trigger: draft) { (old: Int?, new: Int?) -> SensoryFeedback? in
        // A thump when the placeholder appears, a tick each time it moves to another slot.
        guard new != nil else { return nil }
        return old == nil ? .impact(weight: .medium) : .selection
      }
    }

    /// The placeholder under the finger while a new event is placed, like Apple's "New Event" block.
    private func draftBlock(_ minute: Int, width: CGFloat) -> some View {
      let start = cal.date(byAdding: .minute, value: minute, to: day) ?? day
      let height = CGFloat(axis.height(from: Double(minute), to: Double(minute + 60)))
      return VStack(alignment: .leading, spacing: 0) {
        Text("New Event").font(.system(size: 10, weight: .semibold))
        Text(
          start.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
        ).font(.system(size: 10).monospacedDigit())
      }
      .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
      .padding(3)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
      .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
      .frame(width: width - 2, height: max(1, height - 1))
      .offset(x: 1, y: CGFloat(axis.y(forMinute: Double(minute))))
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("New Event, \(plannerDayLabel(start, runtime: presentation.runtime))")
      .accessibilityIdentifier("calendar.newEventDraft")
    }
  }

  /// The 2 Day grid's empty space, as a UIKit view with a long-press recognizer. SwiftUI gestures that track a drag (a
  /// long-press sequenced with a drag), attached to the grid's content, kept the grid from scrolling at all; a UIKit
  /// long-press on a view inside the scroll view behaves like Apple Calendar's: a swipe scrolls, a still press and drag places.
  /// `changed` gets the point (in this view, which fills the grid) from the moment the press is recognized; `ended` gets
  /// where the finger was lifted, or nil when the press was cancelled.
  private struct SlotPressView: UIViewRepresentable {
    /// Whether a press here may make an event (false on an event or task block, which has its own long-press).
    var isFree: (CGPoint) -> Bool
    var changed: (CGPoint) -> Void
    var ended: (CGPoint?) -> Void

    func makeUIView(context: Context) -> HitView {
      let view = HitView()
      view.isFree = isFree
      view.backgroundColor = .clear
      let press = UILongPressGestureRecognizer(
        target: context.coordinator, action: #selector(Coordinator.handle(_:)))
      press.minimumPressDuration = 0.5
      press.delegate = context.coordinator
      view.addGestureRecognizer(press)
      return view
    }

    func updateUIView(_ view: HitView, context: Context) {
      view.isFree = isFree
      context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // Reject occupied points before choosing the UIKit touch target, not only when the long press begins.
    final class HitView: UIView {
      var isFree: (CGPoint) -> Bool = { _ in true }

      override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && isFree(point)
      }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var parent: SlotPressView
      init(_ parent: SlotPressView) { self.parent = parent }

      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        parent.isFree(recognizer.location(in: recognizer.view))
      }

      @objc func handle(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began, .changed: parent.changed(press.location(in: press.view))
        case .ended: parent.ended(press.location(in: press.view))
        case .cancelled, .failed: parent.ended(nil)
        default: break
        }
      }
    }
  }

  extension CGRect {
    init(_ f: CalendarLayout.Frame) {
      self.init(x: f.x, y: f.y, width: f.width, height: f.height)
    }
  }

  /// Quiet cues on the 2 Day and Month grids: days that are over are dimmed (a Setting). Weekends look like any other day.
  enum DayTint {
    /// Opacity of event blocks on days that are over.
    static let past = 0.55
    /// Year: the day number of a holiday or festival.
    static let holiday = Color.red
    /// Year: a day that is unusually busy for you (see `YearBusy`). Neutral on purpose: color is for what a day is, not how full.
    static let busyDay = Color(
      UIColor { t in
        t.userInterfaceStyle == .dark
          ? UIColor(white: 0.92, alpha: 0.22) : UIColor(white: 0.24, alpha: 0.16)
      })
  }

  /// Accessibility identifiers for days and months, in the local time zone ("day.2026-10-15", "miniMonth.2026-10") so UI tests can find them.
  enum CalendarIDs {
    static func day(_ d: Date, calendar: Calendar) -> String {
      let c = calendar.dateComponents([.year, .month, .day], from: d)
      return String(format: "day.%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func month(_ d: Date, calendar: Calendar) -> String {
      let c = calendar.dateComponents([.year, .month], from: d)
      return String(format: "miniMonth.%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
  }

#endif

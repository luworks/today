#if os(iOS)
  import One
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Search everything in one place: reminders, calendar events (Today's and the whole system calendar) and alarms.
  /// Native search field with scopes; results are grouped, and tapping one opens it in its own editor.
  package struct SearchView<Editor: View>: View {
    private let editor: @MainActor (OpenedEntry) -> Editor
    private let calendar: any CalendarService
    private let memory: SearchMemory
    package init(
      calendar: any CalendarService, defaults: UserDefaults,
      @ViewBuilder editor: @escaping @MainActor (OpenedEntry) -> Editor
    ) {
      self.calendar = calendar
      self.memory = SearchMemory(defaults: defaults)
      self.editor = editor
      _recents = State(initialValue: SearchMemory(defaults: defaults).load())
    }
    @Environment(PlannerPresentation.self) private var presentation
    enum Scope: String, CaseIterable, Identifiable {
      case all = "All"
      case reminders = "Reminders"
      case events = "Events"
      case alarms = "Alarms"
      var id: Self { self }
    }

    private enum Opened: Identifiable {
      case task(OneTask)
      case event(OneEvent)
      case system(String)
      case alarm(OneAlarm)
      var id: String {
        switch self {
        case .task(let t): "t\(t.persistentModelID.hashValue)"
        case .event(let e): "e\(e.persistentModelID.hashValue)"
        case .system(let s): "s\(s)"
        case .alarm(let a): "a\(a.persistentModelID.hashValue)"
        }
      }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \OneTask.createdAt, order: .reverse) private var tasks: [OneTask]
    @Query(sort: \OneEvent.start) private var events: [OneEvent]
    @Query private var alarms: [OneAlarm]
    @State private var query = ""
    @FocusState private var focused: Bool
    @State private var scope: Scope = .all
    @State private var opened: Opened?
    @State private var recents: [String]
    @State private var quick: Quick?
    @State private var calendarSnapshot: CalendarSnapshot?

    private struct CalendarRequest: Equatable {
      let day: Date
      let upcomingOnly: Bool
      let version: Int
      let ready: Bool
      let hiddenCalendars: Set<String>
      let calendar: Calendar

      func window(now: Date) -> DateInterval {
        if upcomingOnly {
          return DateInterval(
            start: now, end: calendar.date(byAdding: .day, value: 7, to: now) ?? now)
        }
        return DateInterval(
          start: calendar.date(byAdding: .year, value: -2, to: now) ?? now,
          end: calendar.date(byAdding: .year, value: 2, to: now) ?? now)
      }
    }

    private struct CalendarSnapshot {
      let request: CalendarRequest
      let events: [ExternalEvent]
    }

    /// Query characters only filter values. Source reads run once per range/version in the view task.
    private var calendarRequest: CalendarRequest? {
      guard calendar.isOn else { return nil }
      let cal = presentation.calendar
      let today = cal.startOfDay(for: presentation.now)
      let empty = query.trimmingCharacters(in: .whitespaces).isEmpty
      if empty {
        guard quick == .events else { return nil }
      } else {
        guard scope == .all || scope == .events else { return nil }
      }
      return CalendarRequest(
        day: today, upcomingOnly: empty, version: calendar.version,
        ready: calendar.isReady, hiddenCalendars: calendar.hiddenCalendarIDs, calendar: cal)
    }

    /// Reject stale/disabled snapshots immediately, before the replacement task gets its turn.
    private var systemEvents: [ExternalEvent] {
      guard let request = calendarRequest, let calendarSnapshot,
        calendarSnapshot.request == request
      else { return [] }
      let mirrors = Set(events.compactMap(\.externalID))
      return calendarSnapshot.events.filter { !mirrors.contains($0.eventIdentifier) }
    }

    private let limit = 25

    /// Suggested searches shown before you type: they list things without needing words.
    enum Quick: String, CaseIterable, Identifiable {
      case overdue = "Overdue"
      case today = "Due today"
      case flagged = "Flagged"
      case events = "Upcoming events"
      case alarms = "Alarms on"
      var id: Self { self }
      var symbol: String {
        switch self {
        case .overdue: "exclamationmark.circle"
        case .today: "sun.max"
        case .flagged: "flag"
        case .events: "calendar"
        case .alarms: "alarm"
        }
      }
      var tint: Color {
        switch self {
        case .overdue: .red
        case .today: .blue
        case .flagged: .orange
        case .events: .indigo
        case .alarms: .orange
        }
      }
    }

    package var body: some View {
      NavigationStack {
        let r = results
        List {
          if !query.isEmpty {
            PillSwitcher(
              items: Scope.allCases, selection: $scope,
              title: { $0.rawValue }, identifier: { "search.scope." + $0.rawValue.lowercased() }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          }
          if query.isEmpty, quick == nil {
            Section("Suggestions") {
              ForEach(Quick.allCases) { q in
                Button {
                  quick = q
                } label: {
                  Label {
                    Text(q.rawValue).foregroundStyle(.primary)
                  } icon: {
                    Image(systemName: q.symbol).foregroundStyle(q.tint)
                  }
                }
              }
            }
            if !recents.isEmpty {
              Section {
                ForEach(recents, id: \.self) { term in
                  Button {
                    query = term
                  } label: {
                    Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                  }
                }
              } header: {
                HStack {
                  Text("Recent")
                  Spacer()
                  Button("Clear") {
                    memory.clear()
                    recents = []
                  }.font(.footnote)
                }
              }
            }
          } else {
            if let quick {
              Section {
                Button {
                  self.quick = nil
                } label: {
                  Label("\(quick.rawValue) · Clear", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                }
              }
            }
            if !r.tasks.isEmpty {
              Section(header: header("Reminders", r.tasks.count)) {
                ForEach(r.tasks.prefix(limit)) { task in
                  Button {
                    PerformanceTrace.shared.beginPage("reminder.editor")
                    opened = .task(task)
                  } label: {
                    ResultRow(
                      symbol: task.isDone ? "checkmark.circle.fill" : "circle",
                      tint: task.isDone ? .green : .blue,
                      title: task.title, detail: detail(task), dimmed: task.isDone)
                  }
                  .accessibilityIdentifier("search.result")
                }
              }
            }
            if !r.events.isEmpty {
              Section(header: header("Events", r.events.count)) {
                ForEach(r.events.prefix(limit)) { hit in
                  Button {
                    if case .system(let id) = hit.opened {
                      if let native = calendar as? any NativeCalendarService {
                        native.edit(
                          identifier: id, start: hit.start, end: nil, onComplete: nil)
                      } else {
                        opened = hit.opened
                      }
                    } else {
                      opened = hit.opened
                    }
                  } label: {
                    ResultRow(
                      symbol: "calendar", tint: hit.color, title: hit.title, detail: hit.detail,
                      dimmed: hit.start < presentation.now)
                  }
                  .accessibilityIdentifier("search.result")
                }
              }
            }
            if !r.alarms.isEmpty {
              Section(header: header("Alarms", r.alarms.count)) {
                ForEach(r.alarms) { alarm in
                  Button {
                    opened = .alarm(alarm)
                  } label: {
                    alarmRow(alarm)
                  }
                  .accessibilityIdentifier("search.result")
                }
              }
            }
          }
        }
        .listStyle(.insetGrouped)
        .performanceDestination(query.isEmpty ? "search" : "search.results")
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .overlay {
          if !query.isEmpty || quick != nil, r.isEmpty {
            ContentUnavailableView.search(text: query)
          }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
        .task(id: calendarRequest) {
          guard !Task.isCancelled else { return }
          if let request = calendarRequest {
            let values = calendar.events(in: request.window(now: presentation.now))
            calendarSnapshot = CalendarSnapshot(request: request, events: values)
          } else {
            calendarSnapshot = nil
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active, calendarRequest != nil { calendar.refresh() }
        }
        .sheet(item: $opened) { item in
          switch item {
          case .task(let t): editor(.task(t))
          case .event(let e): editor(.local(e))
          case .system(let id): editor(.system(id))
          case .alarm(let a): editor(.alarm(a))
          }
        }
      }
    }

    /// Our own search bar: the field, and an X that closes Search straight away (no empty page or pop-up left behind).
    private var searchBar: some View {
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(
            "Reminders, events, alarms", text: $query.performanceAction { _ in "search.results" }
          )
          .focused($focused)
          .submitLabel(.search)
          .autocorrectionDisabled()
          .onSubmit {
            memory.add(query)
            recents = memory.load()
          }
          .accessibilityIdentifier("search.field")
          if !query.isEmpty {
            Button {
              query = ""
              focused = true
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Clear text")
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.secondarySystemFill), in: Capsule())
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glassCircle()
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Close search")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
    }

    private func header(_ title: String, _ count: Int) -> some View {
      HStack {
        Text(title)
        Spacer()
        Text("\(count)").monospacedDigit()
      }
    }

    // MARK: Results

    private struct EventHit: Identifiable {
      let id: String
      let title: String
      let detail: String
      let start: Date
      let color: Color
      let opened: Opened
    }

    private struct Results {
      var tasks: [OneTask] = []
      var events: [EventHit] = []
      var alarms: [OneAlarm] = []
      var isEmpty: Bool { tasks.isEmpty && events.isEmpty && alarms.isEmpty }
    }

    private var results: Results {
      if query.trimmingCharacters(in: .whitespaces).isEmpty, let quick {
        return quickResults(quick)
      }
      let q = query.trimmingCharacters(in: .whitespaces)
      guard !q.isEmpty else { return Results() }
      var out = Results()
      if scope == .all || scope == .reminders {
        out.tasks = tasks.filter {
          SearchMatch.matches(q, in: [$0.title, $0.note, $0.listName] + $0.tags)
        }
        .sorted {
          ($0.isDone ? 1 : 0, $0.due ?? .distantFuture) < (
            $1.isDone ? 1 : 0, $1.due ?? .distantFuture
          )
        }
      }
      if scope == .all || scope == .events {
        var hits: [EventHit] = events.filter {
          SearchMatch.matches(q, in: [$0.title, $0.calendarName])
        }.map { e in
          EventHit(
            id: "o\(e.persistentModelID.hashValue)", title: e.title,
            detail: dateLabel(e.start) + " · " + e.calendarName, start: e.start, color: .blue,
            opened: .event(e))
        }
        // The whole system calendar, two years either side of today (events Today mirrored are not listed twice).
        let window = DateInterval(
          start: presentation.calendar.date(byAdding: .year, value: -2, to: presentation.now)
            ?? presentation.now,
          end: presentation.calendar.date(byAdding: .year, value: 2, to: presentation.now)
            ?? presentation.now)
        for s in systemEvents
        where s.start < window.end && s.end > window.start
          && SearchMatch.matches(q, in: [s.title, s.location, s.calendarTitle])
        {
          hits.append(
            EventHit(
              id: "s\(s.id)", title: s.title, detail: dateLabel(s.start) + " · " + s.calendarTitle,
              start: s.start, color: s.color, opened: .system(s.eventIdentifier)))
        }
        // Upcoming first (soonest first), then the past (most recent first).
        let now = presentation.now
        out.events =
          hits.filter { $0.start >= now }.sorted { $0.start < $1.start }
          + hits.filter { $0.start < now }.sorted { $0.start > $1.start }
      }
      if scope == .all || scope == .alarms {
        out.alarms = alarms.filter {
          SearchMatch.matches(q, in: [$0.label, alarmTime($0), $0.repeatValue, "alarm"])
        }
        .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      }
      return out
    }

    private func quickResults(_ q: Quick) -> Results {
      let cal = presentation.calendar
      var out = Results()
      switch q {
      case .overdue:
        out.tasks = tasks.filter { task in
          guard !task.isDone, let due = task.due else { return false }
          return presentation.calendar.startOfDay(for: due)
            < presentation.calendar.startOfDay(for: presentation.now)
        }.sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
      case .today:
        out.tasks = tasks.filter { t in
          guard !t.isDone else { return false }
          if let d = t.due, cal.isDate(d, inSameDayAs: presentation.now) { return true }
          return false
        }
      case .flagged:
        out.tasks = tasks.filter { $0.flagged && !$0.isDone }
      case .events:
        let end = cal.date(byAdding: .day, value: 7, to: presentation.now) ?? presentation.now
        let window = DateInterval(start: presentation.now, end: end)
        var hits: [EventHit] = events.compactMap { e in
          guard
            let next = Recurrence.occurrences(
              start: e.start, duration: e.duration, rule: e.repeats, in: window, calendar: cal
            ).first(where: { $0 >= presentation.now })
          else { return nil }
          return EventHit(
            id: "o\(e.persistentModelID.hashValue)", title: e.title,
            detail: dateLabel(next) + " · " + e.calendarName, start: next, color: .blue,
            opened: .event(e))
        }
        for s in systemEvents where s.start >= presentation.now && s.start < window.end {
          hits.append(
            EventHit(
              id: "s\(s.id)", title: s.title, detail: dateLabel(s.start) + " · " + s.calendarTitle,
              start: s.start, color: s.color, opened: .system(s.eventIdentifier)))
        }
        out.events = hits.sorted { $0.start < $1.start }
      case .alarms:
        out.alarms = alarms.filter(\.isOn).sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      }
      return out
    }

    private func dateLabel(_ date: Date) -> String {
      plannerDayLabel(date, runtime: presentation.runtime)
    }

    private func detail(_ t: OneTask) -> String {
      var parts: [String] = []
      if let due = t.due {
        parts.append("Due " + dateLabel(due))
      }
      if !t.listName.isEmpty { parts.append(ListName.display(t.listName)) }
      return parts.joined(separator: " · ")
    }

    private func alarmRow(_ alarm: OneAlarm) -> some View {
      let title = alarm.label.isEmpty ? "Alarm" : alarm.label
      let detail = alarmTime(alarm) + " · " + alarm.repeatValue
      return ResultRow(
        symbol: "alarm", tint: .orange, title: title, detail: detail, dimmed: !alarm.isOn)
    }

    private func alarmTime(_ a: OneAlarm) -> String {
      let p = AlarmPlan.timeParts(hour: a.hour, minute: a.minute, locale: presentation.locale)
      return p.time + (p.suffix.map { " " + $0 } ?? "")
    }
  }

  private struct ResultRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var dimmed = false

    var body: some View {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.body.weight(.semibold))
          .foregroundStyle(tint.contrastForeground(for: colorScheme))
          .frame(width: 30, height: 30)
          .background(tint.gradient, in: Circle())
        TitleDetail(
          title: Text(title).foregroundStyle(dimmed ? .secondary : .primary),
          hasDetail: !detail.isEmpty
        ) {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  /// The last few searches the user submitted, kept on the device.
  private struct SearchMemory {
    let defaults: UserDefaults
    private let key = "today.search.recents"
    func load() -> [String] { defaults.stringArray(forKey: key) ?? [] }
    func clear() { defaults.removeObject(forKey: key) }
    func add(_ term: String) {
      let t = term.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { return }
      let list = ([t] + load().filter { $0.caseInsensitiveCompare(t) != .orderedSame }).prefix(6)
      defaults.set(Array(list), forKey: key)
    }
  }

#endif

#if DEBUG
  import SwiftUI
  import SwiftData
  import UIKit
  import TodayCore
  import TodayScenes
  import TodayTestSupport
  import FeatureClock
  import FeatureHealth
  import One
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import TodayPlannerUI
  import FeatureToday
  import FeatureCalendar
  import FeatureReminders
  import FeatureAsk
  import FeatureSettings
  import FeatureActivity
  import FeatureSearch

  /// Each scene is an independent composition root. Features receive only their narrow capabilities.
  @MainActor
  final class SceneSession {
    let identity = UUID()
    let configuration: SceneConfiguration
    let container: ModelContainer
    let defaults: UserDefaults
    let runtimeState: SceneRuntimeState
    let runtime: PlannerRuntime
    let services: PlannerTestServices
    let presentation: PlannerPresentation
    let health: HealthModel
    let healthLine: HealthLineModel
    let weather: WeatherModel
    let healthSelection: HealthSelectionStore
    let healthGate: HealthAccessGate
    let world: WorldClockStore
    let stopwatch: StopwatchModel
    let toast = UndoToast()
    let undoManager = UndoManager()
    let askCapabilities: SceneAskCapabilities
    let speech: SceneSpeechDriver
    let voice: VoiceInput
    let suggestionMemory = AskSuggestionMemory()
    let diagnostics = LocalDiagnostics()
    let exportDirectory: URL
    private let suiteName: String
    private var disposed = false
    private(set) var settingsOpenCount = 0
    private(set) var widgetRewriteCount = 0
    private(set) var capturesAddedCount = 0
    private(set) var approvedPlanCount = 0

    init(
      configuration: SceneConfiguration, datasetURL: URL? = SceneSession.bundledDataset,
      citiesURL: URL? = SceneSession.bundledCities
    ) throws {
      self.configuration = configuration
      runtimeState = SceneRuntimeState(configuration: configuration)
      runtime = runtimeState.runtime
      suiteName = "today.workbench.\(identity.uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw SceneSessionError.defaults
      }
      self.defaults = defaults
      var completed = false
      let disposableSuite = suiteName
      defer { if !completed { defaults.removePersistentDomain(forName: disposableSuite) } }
      exportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TodayWorkbench", isDirectory: true)
        .appendingPathComponent(identity.uuidString, isDirectory: true)
      container = try ModelContainer(
        for: OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, Habit.self,
        ChatThread.self, LedgerEntry.self, AIGrant.self, ShareImportReceipt.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
      container.mainContext.autosaveEnabled = false
      if configuration.scenario != .empty || configuration.scene == .remindersList {
        guard let datasetURL else { throw SceneSessionError.missingDataset }
        try Self.loadFixture(
          datasetURL, into: container.mainContext, now: configuration.now, runtime: runtime)
        if configuration.scenario == .dense {
          for offset in 1...5 {
            try Self.loadFixture(
              datasetURL, into: container.mainContext,
              now: configuration.now.addingTimeInterval(Double(offset) * 60), runtime: runtime)
          }
        }
      }
      if configuration.scenario == .empty, configuration.scene == .remindersList {
        try container.mainContext.delete(model: OneTask.self)
        try container.mainContext.delete(model: OneEvent.self)
        try container.mainContext.delete(model: OneAlarm.self)
        try container.mainContext.delete(model: ChatThread.self)
        try container.mainContext.save()
      }
      var arguments: [String] = []
      if configuration.scenario != .empty {
        arguments = [
          "-uiTestingTimers",
          configuration.scenario == .dense
            ? "600:Pasta,1500:Focus,300:Tea:paused,60:Eggs:ringing" : "600:Pasta,300:Tea:paused",
          "-uiTestingRecents", "420,1200,1800:Read",
        ]
      }
      services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime, arguments: arguments)
      let retainedServices = services
      defer { if !completed { retainedServices.dispose() } }
      presentation = PlannerPresentation(runtime: runtime, defaults: defaults)
      healthSelection = HealthSelectionStore(
        defaults: defaults,
        initialSelection:
          configuration.scenario == .dense
          ? HealthSelection(shown: HealthMetric.allCases) : .default)
      healthGate = HealthAccessGate()
      let baseHealth = SceneHealthSource(configuration: configuration)
      let source: any HealthSource = baseHealth
      health = HealthModel(
        source: source, store: healthSelection, runtime: runtime, gate: healthGate,
        timeout: configuration.scenario == .error ? 0.05 : HealthTimeout.seconds)
      healthLine = HealthLineModel(model: health)
      weather = WeatherModel(sample: WeatherTestData.snapshot(now: runtime.now()))
      guard let citiesURL else { throw SceneSessionError.missingCities }
      let cities = try CityDatabase.decode(Data(contentsOf: citiesURL))
      let keys =
        configuration.scenario == .empty
        ? []
        : configuration.scenario == .dense
          ? Array(cities.cities.prefix(12).map(\.key))
          : ["Europe/London", "Asia/Shanghai", "America/New_York"]
      world = WorldClockStore(
        database: cities, defaults: defaults,
        homeZoneIdentifier: configuration.timeZoneIdentifier, initialKeys: keys)
      let laps: [Double] =
        configuration.scenario == .dense ? [4.2, 6.5, 5.1, 8.2, 3.3, 6.8, 4.1, 9.2] : []
      let elapsed = configuration.scenario == .empty ? 0.0 : 5.75
      stopwatch = StopwatchModel(
        defaults: defaults, now: runtime.now,
        initialState: StopwatchState(
          startedAt: nil, accumulated: elapsed + laps.reduce(0, +), laps: laps),
        initialPage: .analog)
      askCapabilities = SceneAskCapabilities(scenario: configuration.scenario)
      speech = SceneSpeechDriver(scenario: configuration.scenario)
      voice = VoiceInput(driver: speech)
      toast.undoManager = undoManager
      configureScenario()
      if configuration.scenario != .empty {
        let tasks = try container.mainContext.fetch(
          FetchDescriptor<OneTask>(sortBy: [SortDescriptor(\.createdAt)]))
        if let linkedTask = tasks.first(where: { !$0.isDone }) {
          linkedTask.externalID = "scene.reminder"
          try container.mainContext.save()
        }
        for task in tasks.prefix(configuration.scenario == .dense ? 40 : 3) {
          services.ledger.record(
            .created, task: task, title: task.title, context: container.mainContext)
        }
        services.ledger.flush(container.mainContext)
        services.activity.recorder.flush()
      }
      completed = true
    }

    static var bundledCities: URL? {
      if let url = Bundle.main.url(forResource: "cities", withExtension: "json") { return url }
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      let url = root.appendingPathComponent("One/cities.json")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func configureScenario() {
      let denied = configuration.scenario == .denied || configuration.scenario == .revoked
      services.calendar.enabled = true
      services.calendar.hasAccess = !denied
      services.calendar.availableCalendars = [
        SystemCalendar(
          id: "workbench", title: "Workbench", sourceTitle: "Local session", color: .blue)
      ]
      if configuration.scenario != .empty {
        services.calendar.queryEvents = [
          ExternalEvent(
            id: "scene.external", eventIdentifier: "scene.external",
            title: "Read-only shared calendar event",
            start: configuration.now.addingTimeInterval(3600),
            end: configuration.now.addingTimeInterval(7200), isAllDay: false,
            calendarID: "workbench", calendarTitle: "Workbench", color: .blue)
        ]
      }
      services.calendar.isQuerying = configuration.scenario == .loading
      services.calendar.isReady = configuration.scenario != .loading
      services.calendar.lastError =
        configuration.scenario == .error ? "Local calendar fixture failed to load." : nil
      services.reminders.connectionGranted = !denied
      services.reminders.hasAccess = !denied
      services.reminders.isConnected = !denied
      services.reminders.isDenied = denied
      services.reminders.isReconciling = configuration.scenario == .loading
      services.reminders.lastError =
        configuration.scenario == .error ? "Local reminders fixture failed to load." : nil
      services.reminders.completionFailure = configuration.scenario == .error ? .injected : nil
      services.alarms.authorization = denied ? .denied : .authorized
      services.alarms.authorizationResponse = denied ? .denied : .authorized
      services.alarms.isAvailable = configuration.scenario != .unavailable
      services.notifications.status = denied ? .denied : .authorized
      services.notifications.permissionResponse = !denied
      services.timers.message =
        configuration.scenario == .error ? "Local timer fixture failed to load." : nil
    }

    func advanceClock(by seconds: TimeInterval) {
      runtimeState.advance(by: seconds)
      services.timers.liveStates = Dictionary(
        uniqueKeysWithValues: services.timers.timers.map { timer in
          (
            timer.id,
            services.timers.ringing.contains(timer.id) || timer.ranToEnd(now: runtime.now())
              ? LiveTimerState.ringing : timer.isPaused ? .paused : .running
          )
        })
      services.timers.refresh()
    }

    func openSettings() {
      settingsOpenCount += 1
      toast.showNotice("System Settings are unavailable in this local session.")
    }
    func rewriteWidgets() { widgetRewriteCount += 1 }
    func captureAdded(_ capture: Capture) { capturesAddedCount += 1 }
    func planApproved(_ count: Int) { approvedPlanCount += count }
    func exportDestination(_ format: ActivityExportFormat) throws -> URL {
      try FileManager.default.createDirectory(
        at: exportDirectory, withIntermediateDirectories: true)
      return exportDirectory.appendingPathComponent(
        "activity-\(runtime.nextID().uuidString).\(format == .csv ? "csv" : "jsonl")")
    }
    func reset(_ context: ModelContext) {
      if !DataReset.run(
        context, reminders: services.reminders, ledger: services.ledger, inbox: SceneEmptyInbox(),
        focus: services.actions.focus)
      {
        toast.showNotice("Couldn't clear saved Focus choices. Your local data was kept. Try again.")
      }
    }
    func alarmCreated(_ alarm: OneAlarm, context: ModelContext) {
      AlarmActions.recordCreated(
        alarm, title: alarm.label.isEmpty ? "Alarm" : alarm.label, ledger: services.ledger,
        runtime: runtime, context: context)
    }

    /// Explicitly apply at UIKit hosting roots as well as the SwiftUI entry and detached sheets.
    func host<V: View>(_ view: V) -> some View {
      view.modelContainer(container).defaultAppStorage(defaults)
        .environment(services.actions).environment(presentation).environment(toast)
        .environment(health).environment(healthLine).environment(weather)
        .environment(\.locale, runtime.locale).environment(\.calendar, runtime.calendar)
        .environment(\.timeZone, runtime.calendar.timeZone)
        .environment(
          \.layoutDirection,
          runtime.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    /// Bundle the existing fixture in Mock/Workbench; source-path fallback supports local previews only.
    static var bundledDataset: URL? {
      if let url = Bundle.main.url(forResource: "today-dataset", withExtension: "json") {
        return url
      }
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let source = root.appendingPathComponent("tests/fixtures/today-dataset.json")
      return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    func dispose() {
      guard !disposed else { return }
      disposed = true
      voice.stop()
      askCapabilities.dispose()
      suggestionMemory.dispose()
      toast.dispose()
      undoManager.removeAllActions()
      services.dispose()
      diagnostics.stop()
      try? FileManager.default.removeItem(at: exportDirectory)
      defaults.removePersistentDomain(forName: suiteName)
    }

    /// Decode the versioned fixture without TestDataset's model toggleDone/system-clock path.
    private static func loadFixture(
      _ url: URL, into context: ModelContext, now: Date, runtime: PlannerRuntime
    ) throws {
      let fixture = try JSONDecoder().decode(TestDataset.File.self, from: Data(contentsOf: url))
      let calendar = runtime.calendar
      let today = calendar.startOfDay(for: now)
      func date(_ value: TestDataset.When?) -> Date? {
        guard let value, let day = calendar.date(byAdding: .day, value: value.day, to: today) else {
          return nil
        }
        guard let time = value.time else { return day }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return day }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
      }
      for (index, row) in (fixture.lists ?? []).enumerated() {
        let list = OneList(
          name: row.name, colorIndex: row.color ?? index, symbol: "list.bullet", order: index)
        list.createdAt = now
        context.insert(list)
      }
      for (index, row) in fixture.reminders.enumerated() {
        let task = OneTask(
          title: row.title, note: row.note ?? "",
          durationMinutes: row.minutes ?? 25, due: date(row.due) ?? date(row.planned))
        task.createdAt = now.addingTimeInterval(-Double(index))
        task.listName = row.list ?? ""
        task.flagged = row.flagged ?? false
        task.tags = row.tags ?? []
        task.repeatRule = row.repeat.flatMap { RepeatRule(rawValue: $0)?.rawValue }
        task.checklist = (row.checklist ?? []).map {
          ChecklistItem(id: runtime.nextID(), title: $0.title, done: $0.done ?? false)
        }
        task.ringsAsAlarm = row.ringsAsAlarm ?? false
        task.isDone = row.done ?? false
        task.doneAt = task.isDone ? now.addingTimeInterval(-60) : nil
        context.insert(task)
      }
      for row in fixture.events {
        guard let start = date(row.start) else { continue }
        let event = OneEvent(title: row.title, start: start, durationMinutes: row.minutes)
        event.isAllDay = row.allDay ?? false
        event.repeatRule = row.repeat.flatMap { RepeatRule(rawValue: $0)?.rawValue }
        context.insert(event)
      }
      for row in fixture.alarms {
        let parts = row.time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { continue }
        let alarm = OneAlarm(
          hour: parts[0], minute: parts[1], label: row.label ?? "", weekdays: row.weekdays ?? [],
          snooze: row.snooze ?? true)
        alarm.createdAt = now
        alarm.alarmKitID = runtime.nextID()
        alarm.isOn = row.on ?? true
        context.insert(alarm)
      }
      for row in fixture.chats {
        let timestamp = now.addingTimeInterval(-row.hoursAgo * 3600)
        let messages = row.messages.compactMap { pair -> ChatMessage? in
          guard pair.count == 2, let role = ChatMessage.Role(rawValue: pair[0]) else { return nil }
          return ChatMessage(id: runtime.nextID(), role: role, text: pair[1], timestamp: timestamp)
        }
        let thread = ChatThread(
          title: row.title, messages: messages, createdAt: timestamp, updatedAt: timestamp,
          id: runtime.nextID())
        thread.archived = row.archived ?? false
        context.insert(thread)
      }
      try context.save()
    }
  }

  @MainActor
  extension SceneSession {
    func taskEditor(_ task: OneTask?) -> some View {
      TaskEditor(
        task: task, actions: services.actions, ledger: services.ledger,
        reminders: services.reminders, alarms: services.alarms, presentation: presentation)
    }
    func eventEditor(event: OneEvent? = nil, day: Date? = nil, start: Date? = nil, end: Date? = nil)
      -> some View
    {
      EventEditor(
        event: event, day: day, start: start, end: end, calendar: services.calendar,
        actions: services.actions, ledger: services.ledger, alarms: services.alarms,
        presentation: presentation)
    }
    func alarmEditor(_ alarm: OneAlarm?) -> some View {
      AlarmEditor(
        alarm: alarm, alarms: services.alarms, soundPreview: services.soundPreview,
        runtime: runtime, defaults: defaults, onCreated: alarmCreated)
    }
    var timerView: some View {
      TimerSection(
        controller: services.timers, alarms: services.alarms, soundPreview: services.soundPreview)
    }
    func unsupportedNativeEvent(_ identifier: String) -> some View {
      let event = services.calendar.queryEvents.first { $0.eventIdentifier == identifier }
      return ContentUnavailableView(
        "Native calendar editing unavailable", systemImage: "calendar.badge.exclamationmark",
        description: Text(
          event.map {
            "\($0.title) is a read-only fixture in this local session. Use a local event to exercise Save and Undo."
          }
            ?? "This system event is unavailable in the local session. No event was changed.")
      )
      .accessibilityIdentifier("scene.nativeCalendarUnsupported")
    }
    func hostingController<V: View>(rootView: V) -> UIViewController {
      UIHostingController(rootView: host(rootView))
    }
  }

  /// The supplied diagnostics API exports on explicit tap. Retain a session-specific copy for sharing.
  @MainActor
  private struct SceneDiagnosticExport: View {
    let session: SceneSession
    let source: URL
    @State private var result: Result<URL, Error>?
    var body: some View {
      Group {
        switch result {
        case .success(let url): SceneShareSheet(url: url)
        case .failure(let error): SceneFailure(error: error)
        case nil: ProgressView("Preparing export")
        }
      }
      .task {
        guard result == nil else { return }
        result = Result {
          try FileManager.default.createDirectory(
            at: session.exportDirectory, withIntermediateDirectories: true)
          let destination = session.exportDirectory.appendingPathComponent(
            "diagnostics-\(session.runtime.nextID().uuidString).json")
          try FileManager.default.copyItem(at: source, to: destination)
          return destination
        }
      }
    }
  }

  private struct SceneShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
  }

  enum SceneSessionError: Error, CustomStringConvertible {
    case defaults, missingDataset, missingCities
    var description: String {
      switch self {
      case .defaults: "Could not create isolated Workbench defaults."
      case .missingDataset: "Bundle tests/fixtures/today-dataset.json in the development target."
      case .missingCities: "Bundle ios/One/cities.json in the development target."
      }
    }
  }

  private struct SceneHealthSource: HealthSource {
    let configuration: SceneConfiguration
    var isAvailable: Bool { configuration.scenario != .unavailable }
    var isSample: Bool { true }
    func requestAccess(for metrics: [HealthMetric]) async {}
    func series(for metrics: [HealthMetric], days: Int, now: Date) async -> [HealthMetric:
      HealthSeries]
    {
      if configuration.scenario == .loading || configuration.scenario == .error {
        do {
          try await Task.sleep(for: .seconds(configuration.scenario == .loading ? 60 : 3))
        } catch { return [:] }
      }
      return Dictionary(
        uniqueKeysWithValues: metrics.map {
          (
            $0,
            [.empty, .denied, .revoked].contains(configuration.scenario)
              ? .empty
              : HealthSampleSeries.series(
                for: $0, now: configuration.now, calendar: configuration.calendar)
          )
        })
    }
    func preferredUnits() async -> HealthUnits? {
      HealthUnits(locale: Locale(identifier: configuration.localeIdentifier))
    }
  }

  /// The single typed native factory used by Workbench, #Preview and screenshot entry points.
  /// Session creation is throwing: unsupported combinations never turn into a plausible default screen.
  @MainActor
  struct SceneCatalog: View {
    let session: SceneSession
    var body: some View {
      SceneCatalogContent(session: session).id(session.identity)
    }
  }

  @MainActor
  private struct SceneCatalogContent: View {
    let session: SceneSession
    @State private var day: Date
    @State private var mode: CalendarView.Mode
    @State private var clock: ClockSection = .alarms
    @State private var path: [ReminderTarget] = []
    @State private var pushed = false
    @State private var shownMetrics: Set<HealthMetric> = Set(HealthMetric.defaults)
    @State private var sound = ""
    @State private var opened: OpenedEntry?
    @State private var afterEditor: (() -> Void)?
    @State private var showsTimer = false
    @State private var showsDay = false
    @State private var askClosed = false

    init(session: SceneSession) {
      self.session = session
      _day = State(initialValue: session.configuration.now)
      let id = session.configuration.scene
      _mode = State(
        initialValue: id == .calendarYear ? .year : id == .calendarMonth ? .month : .twoDay)
    }

    var body: some View {
      session.host(content)
        .sheet(
          item: $opened,
          onDismiss: {
            let completion = afterEditor
            afterEditor = nil
            completion?()
          }
        ) { session.host(editor($0)) }
        .sheet(isPresented: $showsTimer) { session.host(session.timerView) }
        .sheet(isPresented: $showsDay) { session.host(NavigationStack { agenda }) }
        .overlay(alignment: .bottom) { session.host(UndoToastView()) }
        .overlay(alignment: .topTrailing) {
          if session.configuration.scene == .clockStopwatch
            || session.configuration.scene == .clockTimer
          {
            Button("Advance 1 minute") {
              session.advanceClock(by: 60)
            }
            .font(.caption).padding(8)
            .accessibilityIdentifier("scene.advanceClock")
          }
        }
    }

    @ViewBuilder private var content: some View {
      switch session.configuration.scene {
      case .today:
        NavigationStack { agenda }
      case .calendarTwoDay, .calendarMonth, .calendarYear:
        NavigationStack {
          CalendarView(
            day: $day, mode: $mode, calendar: session.services.calendar,
            actions: session.services.actions, ledger: session.services.ledger,
            alarms: session.services.alarms,
            onOpenTask: { opened = .task($0) }, onOpenAlarm: { opened = .alarm($0) },
            onOpenDay: {
              day = $0
              showsDay = true
            })
        }
      case .calendarKey: YearKeySheet()
      case .calendarSources: CalendarsSheet(calendar: session.services.calendar)
      case .eventEditor: session.eventEditor(event: events.first, day: day)
      case .reminders:
        RemindersView(
          isPushed: $pushed, path: $path, sync: session.services.reminders,
          actions: session.services.actions, ledger: session.services.ledger,
          alarms: session.services.alarms, presentation: session.presentation,
          openSettings: session.openSettings,
          requestAccess: { await session.services.reminders.connect() })
      case .remindersToday: reminderList(.smart(.today))
      case .remindersScheduled: reminderList(.smart(.scheduled))
      case .remindersAll: reminderList(.smart(.all))
      case .remindersFlagged: reminderList(.smart(.flagged))
      case .remindersCompleted: reminderList(.smart(.completed))
      case .remindersList:
        reminderList(lists.first.map { .list($0.persistentModelID) } ?? .defaultList)
      case .reminderEditor: session.taskEditor(tasks.first)
      case .reminderQuickAdd:
        QuickReminderSheet(
          actions: session.services.actions, ledger: session.services.ledger,
          alarms: session.services.alarms, activity: session.services.activity,
          presentation: session.presentation)
      case .reminderListEditor:
        ListEditor(
          list: lists.first, ledger: session.services.ledger, reminders: session.services.reminders)
      case .clockAlarms:
        AlarmsView(
          section: $clock, alarms: session.services.alarms, timers: session.services.timers,
          notifications: session.services.notifications,
          soundPreview: session.services.soundPreview,
          worldClock: session.world, stopwatch: session.stopwatch, now: session.runtime.now,
          defaults: session.defaults, arguments: ["-uiTesting"],
          onAlarmCreated: session.alarmCreated, showUndo: session.toast.show)
      case .alarmEditor: session.alarmEditor(alarms.first)
      case .alarmSound:
        NavigationStack { SoundScreen(sound: $sound, preview: session.services.soundPreview) }
      case .clockWorld:
        WorldClockView(store: session.world, now: session.runtime.now, showUndo: session.toast.show)
      case .cityPicker: CityPicker(store: session.world, now: session.runtime.now)
      case .clockStopwatch: StopwatchView(model: session.stopwatch)
      case .clockTimer: session.timerView
      case .ask:
        if askClosed {
          Button("Open Ask") { askClosed = false }
            .accessibilityIdentifier("scene.reopenAsk")
        } else {
          AskView(
            thread: chats.first, calendar: session.services.calendar, now: session.runtime.now,
            actions: session.services.actions, ledger: session.services.ledger,
            activity: session.services.activity,
            intelligence: session.askCapabilities.intelligence, agentModel: .unavailable,
            voice: session.voice,
            presentation: session.presentation,
            travel: session.services.travel, suggestionMemory: session.suggestionMemory,
            onBack: { _ in askClosed = true }, onAdded: session.captureAdded,
            onOpenDay: {
              day = $0
              showsDay = true
            },
            onOpenTask: { task, completion in
              afterEditor = completion
              opened = .task(task)
            },
            onOpenAlarm: { alarm, completion in
              afterEditor = completion
              opened = .alarm(alarm)
            })
        }
      case .askCapture, .askStack, .askChange, .askTidy:
        SceneAskCards(session: session)
      case .activity:
        ActivityView(
          activity: session.services.activity,
          flush: { session.services.ledger.flush(session.container.mainContext) },
          undo: {
            await session.services.actions.undo($0, context: session.container.mainContext)
          })
      case .search:
        SearchView(calendar: session.services.calendar, defaults: session.defaults) {
          session.host(editor($0))
        }
      case .settings: settings(.all)
      case .settingsAppearance: settings(.appearance)
      case .settingsApple: settings(.apple)
      case .settingsToday: settings(.today)
      case .settingsCalendar: settings(.calendar)
      case .settingsReminders: settings(.reminders)
      case .settingsSmartLists: settings(.smartLists)
      case .settingsAlarms: settings(.alarms)
      case .settingsAI: settings(.ai)
      case .settingsAbout: settings(.about)
      case .settingsActivity: NavigationStack { activityData }
      case .settingsHolidays:
        NavigationStack { YearHolidaysSettingsView(presentation: session.presentation) }
      case .settingsDelete: settings(.data)
      case .health: HealthView(model: session.health)
      case .healthDetail:
        HealthMetricDetail(
          metric: .steps,
          series: session.configuration.scenario == .empty
            ? .empty
            : HealthSampleSeries.series(
              for: .steps, now: session.configuration.now, calendar: session.configuration.calendar),
          now: session.configuration.now,
          units: HealthUnits(locale: Locale(identifier: session.configuration.localeIdentifier)),
          calendar: session.configuration.calendar, locale: session.runtime.locale)
      case .healthPicker:
        HealthMetricPicker(shown: $shownMetrics)
          .onAppear { shownMetrics = Set(session.healthSelection.selection.shown) }
          .onDisappear {
            session.healthSelection.save(
              HealthSelection(
                shown:
                  session.healthSelection.selection.shown.filter(shownMetrics.contains)
                  + HealthMetric.allCases.filter {
                    shownMetrics.contains($0)
                      && !session.healthSelection.selection.shown.contains($0)
                  }))
          }
      }
    }

    private var agenda: some View {
      DayAgenda(
        day: $day, showsWeekStrip: false, openTask: { opened = .task($0) },
        openEvent: { opened = .local($0) }, openAlarm: { opened = .alarm($0) },
        openTimer: { showsTimer = true },
        actions: session.services.actions, calendar: session.services.calendar,
        timers: session.services.timers,
        reminders: session.services.reminders, ledger: session.services.ledger,
        travel: session.services.travel,
        presentation: session.presentation)
    }

    @ViewBuilder private func editor(_ destination: OpenedEntry) -> some View {
      switch destination {
      case .task(let task): session.taskEditor(task)
      case .local(let event): session.eventEditor(event: event)
      case .alarm(let alarm): session.alarmEditor(alarm)
      case .system(let id), .editSystem(let id): session.unsupportedNativeEvent(id)
      case .new(let start, let end): session.eventEditor(start: start, end: end)
      }
    }

    private var activityData: some View {
      ActivityDataView(
        activity: session.services.activity, exportDestination: session.exportDestination,
        summary: session.services.activity.summary,
        clear: { session.services.activity.clear(context: session.container.mainContext) },
        export: { format, url in try await session.services.activity.export(format, to: url) },
        legacyRowCount: {
          (try? session.container.mainContext.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0
        })
    }

    private func settings(_ selection: SettingsView.Selection) -> some View {
      SettingsView(
        selection: selection, calendar: session.services.calendar,
        reminders: session.services.reminders,
        notifications: session.services.notifications, alarms: session.services.alarms,
        ledger: session.services.ledger,
        openSettings: session.openSettings, rewriteWidgets: session.rewriteWidgets,
        diagnostics: session.diagnostics,
        exportDiagnostics: {
          try session.diagnostics.exportURL(
            to: session.exportDirectory.appendingPathComponent(
              "diagnostics-\(session.runtime.nextID().uuidString).json"))
        },
        calendars: { AnyView(session.host(CalendarsSheet(calendar: session.services.calendar))) },
        holidays: {
          AnyView(session.host(YearHolidaysSettingsView(presentation: session.presentation)))
        },
        activityData: { AnyView(session.host(activityData)) },
        shareDiagnostics: { url in
          AnyView(session.host(SceneDiagnosticExport(session: session, source: url)))
        }, reset: session.reset)
    }

    private func reminderList(_ target: ReminderTarget) -> some View {
      NavigationStack {
        ReminderListScreen(
          target: target, actions: session.services.actions, ledger: session.services.ledger,
          reminders: session.services.reminders, alarms: session.services.alarms)
      }
    }
    private var tasks: [OneTask] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<OneTask>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }
    private var events: [OneEvent] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<OneEvent>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }
    private var lists: [OneList] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<OneList>(sortBy: [SortDescriptor(\.order)]))) ?? []
    }
    private var alarms: [OneAlarm] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<OneAlarm>(sortBy: [
          SortDescriptor(\.hour), SortDescriptor(\.minute), SortDescriptor(\.label),
        ]))) ?? []
    }
    private var chats: [ChatThread] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.title)]))) ?? []
    }
  }

  /// Real product cards, with local selection state and existing creation/planning/undo APIs.
  /// Mutations call the same session actions and native action algorithms as the actual Ask page.
  @MainActor
  private struct SceneAskCards: View {
    let session: SceneSession
    @State private var proposals: [CaptureProposal]
    @State private var tidy: [TidyRow]
    @State private var resolved = false
    @State private var entries: [UUID: LedgerItem] = [:]
    @State private var created: [UUID: PersistentIdentifier] = [:]
    @State private var opened: Opened?

    private struct Opened: Identifiable {
      let id: PersistentIdentifier
    }

    init(session: SceneSession) {
      self.session = session
      let config = session.configuration
      let batch = config.uuid(at: 200)
      let captures = ["Review the design", "Book train tickets", "Water the plants"]
      _proposals = State(
        initialValue: (config.scenario == .empty ? [] : captures).enumerated().map { index, title in
          var proposal = CaptureProposal(
            capture: Capture(title: title, day: config.now, hasDay: true, hour: 14 + index),
            batchSize: config.scene == .askStack ? 3 : 1, batch: batch)
          proposal.id = config.uuid(at: UInt64(201 + index))
          return proposal
        })
      let tasks =
        (try? session.container.mainContext.fetch(
          FetchDescriptor<OneTask>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
      _tidy = State(
        initialValue: tasks.filter { $0.due != nil }.prefix(3).map {
          TidyRow(task: $0, oldDue: $0.due!, choice: .keep)
        })
    }

    private var tasks: [OneTask] {
      (try? session.container.mainContext.fetch(
        FetchDescriptor<OneTask>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }
    var body: some View {
      NavigationStack {
        ScrollView {
          if resolved {
            Label("Preview resolved", systemImage: "checkmark.circle")
          } else if session.configuration.scenario == .empty {
            ContentUnavailableView(
              "No preview", systemImage: "bubble.left",
              description: Text("Open Ask and describe what you would like to prepare."))
          } else {
            switch session.configuration.scene {
            case .askCapture:
              CaptureCard(
                capture: $proposals[0].capture, status: proposals[0].status,
                onAdd: { add(proposals[0].id) }, onCancel: { proposals[0].status = .dropped },
                onUndo: { undo(proposals[0].id) },
                onOpen: { open(proposals[0].id) })
            case .askStack:
              CaptureStack(
                proposals: $proposals, lists: ["Work", "Home"], onAdd: add,
                onSkip: { id in update(id, status: .dropped) },
                onAddAll: { for p in proposals where p.status == .open { add(p.id) } },
                onUndo: undo, onOpen: open, onRename: rename)
            case .askChange:
              if let task = tasks.first {
                let change = PendingChange(
                  subject: .task(task), delete: false, title: task.title,
                  oldText: "Current planned time", newStart: session.configuration.now,
                  notes: [], attendees: 0)
                ChangeCard(
                  change: change,
                  onApply: {
                    feedback(
                      AskNativeActions.applyChange(
                        change, context: session.container.mainContext,
                        calendar: session.services.calendar, actions: session.services.actions,
                        ledger: session.services.ledger, runtime: session.runtime))
                  }, onCancel: { resolved = true })
              }
            case .askTidy:
              TidyCard(
                rows: $tidy,
                onApply: {
                  feedback(
                    AskNativeActions.applyTidy(
                      rows: &tidy, context: session.container.mainContext,
                      actions: session.services.actions, ledger: session.services.ledger,
                      runtime: session.runtime))
                }, onCancel: { resolved = true })
            default: EmptyView()  // This private host is constructed only for the five card IDs.
            }
          }
        }
        .padding()
        .navigationTitle("Ask")
        .sheet(item: $opened) { item in
          let model = session.container.mainContext.model(for: item.id)
          if let task = model as? OneTask {
            session.host(session.taskEditor(task))
          } else if let event = model as? OneEvent {
            session.host(session.eventEditor(event: event))
          } else if let alarm = model as? OneAlarm {
            session.host(session.alarmEditor(alarm))
          }
        }
      }
    }

    private func open(_ id: UUID) {
      guard let item = created[id] else { return }
      opened = Opened(id: item)
    }
    private func update(_ id: UUID, status: CardStatus) {
      if let index = proposals.firstIndex(where: { $0.id == id }) {
        proposals[index].status = status
      }
    }
    private func rename(_ id: UUID, to title: String) -> Bool {
      guard let modelID = created[id],
        session.services.actions.renameCapture(
          Ledger.ref(modelID), to: title, in: session.container.mainContext),
        let index = proposals.firstIndex(where: { $0.id == id })
      else { return false }
      proposals[index].capture.title = title
      return true
    }

    private func add(_ id: UUID) {
      guard let proposal = proposals.first(where: { $0.id == id }),
        proposal.status == .open || proposal.status == .undone
      else { return }
      let result: (id: PersistentIdentifier, entry: LedgerItem)
      do {
        result = try session.services.actions.insert(
          proposal.capture, into: session.container.mainContext,
          actor: .todayAI, channel: .ask, approval: .asked)
      } catch {
        session.toast.showNotice("Could not add this preview. Please try again.")
        return
      }
      created[id] = result.id
      entries[id] = result.entry
      update(id, status: .added)
      session.toast.show("Added") {
        undo(id)
      }
    }
    private func undo(_ id: UUID) {
      guard let entry = entries[id] else { return }
      if session.services.actions.undo(entry, context: session.container.mainContext) {
        update(id, status: .undone)
      }
    }
    private func feedback(_ feedback: AskActionFeedback) {
      resolved = feedback.applied
      if let undo = feedback.undo {
        session.toast.show(undo.label, undo: undo.action)
      } else if let message = feedback.messages.last {
        session.toast.showNotice(message.text)
      }
    }
  }

  struct SceneFailure: View {
    let error: any Error
    var body: some View {
      ContentUnavailableView(
        "Scene unavailable", systemImage: "exclamationmark.triangle",
        description: Text(String(describing: error))
      )
      .accessibilityIdentifier("scene.rejected")
    }
  }
#endif

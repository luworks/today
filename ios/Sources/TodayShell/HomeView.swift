#if os(iOS)
  import One
  import FeatureToday
  import FeatureCalendar
  import FeatureReminders
  import FeatureActivity
  import FeatureSearch
  import FeatureSettings
  import FeatureAsk
  import TodayPlannerUI
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import FeatureClock
  import FeatureHealth
  import SwiftUI
  import SwiftData

  enum HomeTab: String, CaseIterable, Identifiable {
    case today, calendar, tasks, clock

    var id: Self { self }

    var title: String {
      switch self {
      case .today: "Today"
      case .calendar: "Calendar"
      case .tasks: "Reminders"
      case .clock: "Clock"
      }
    }

    var icon: String {
      switch self {
      case .today: "sun.max"
      case .calendar: "calendar"
      case .tasks: "checklist"
      case .clock: "clock"
      }
    }
  }

  /// App shell with secondary tabs above the page and Today, Chat and contextual creation below.
  /// The menu and left-edge swipe open conversation history in the sidebar.
  public struct HomeView: View {
    private let composition: ShellComposition
    private var session: PlannerSession { composition.session }
    private var presentation: PlannerPresentation { composition.presentation }
    private let diagnostics: LocalDiagnostics
    private let prepareData: (@MainActor (ModelContext) async -> Bool)?
    package init(
      composition: ShellComposition, diagnostics: LocalDiagnostics,
      prepareData: (@MainActor (ModelContext) async -> Bool)? = nil
    ) {
      self.composition = composition
      self.diagnostics = diagnostics
      self.prepareData = prepareData
      let defaults = composition.session.defaults
      let args = composition.arguments
      let today = composition.session.runtime.calendar.startOfDay(
        for: composition.session.runtime.now())
      _calendarDay = State(initialValue: today)
      _calendarShown = State(initialValue: today...today)
      _todayDay = State(initialValue: today)
      _todayReferenceNow = State(initialValue: composition.session.runtime.now())
      _tab = State(
        initialValue: Self.restored(
          HomeTab.self, key: Self.tabKey, defaults: defaults, arguments: args) ?? .today)
      _clockSection = State(
        initialValue: Self.restored(
          ClockSection.self, key: Self.clockSectionKey, defaults: defaults, arguments: args)
          ?? .alarms)
      // Read raw: a view that no longer exists (the 7-day "Week", "ThreeDay") is not a mode and opens on 2 Day.
      let last =
        args.contains("-uiTesting") ? nil : defaults.string(forKey: Self.calendarModeKey)
      _calendarMode = State(
        initialValue: CalendarView.Mode(
          rawValue: Preferences.calendarStartChoice(defaults).view(lastUsed: last)) ?? .twoDay)
    }
    @State private var editor: OpenedEntry?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: HomeTab
    @State private var calendarDay: Date
    // Each tab's place is kept here, outside the tab, so leaving a tab and coming back finds it where it was
    // (the open list in Reminders, 2 Day / Month / Year in Calendar, the day in Today).
    @State private var calendarMode: CalendarView.Mode
    /// The first and last day the Calendar page shows, published by it for the top bar's month label.
    @State private var calendarShown: ClosedRange<Date>
    /// Alarms · World Clock · Stopwatch · Timer inside the Clock tab.
    @State private var clockSection: ClockSection
    @State private var addingCity = false
    // The tab and the Calendar view also survive a restart (not in UI tests, which always start the same way).
    private static let tabKey = "today.last.tab", calendarModeKey = "today.last.calendarMode",
      clockSectionKey = "today.last.clockSection"
    private static func restored<T: RawRepresentable>(
      _: T.Type, key: String, defaults: UserDefaults, arguments: [String]
    ) -> T? where T.RawValue == String {
      guard !arguments.contains("-uiTesting") else { return nil }
      // A tab saved under an old name (`alarms`, now `clock`) still opens on the same tab.
      guard let raw = defaults.string(forKey: key) else { return nil }
      return T(rawValue: key == tabKey ? TabMemory.migrated(raw) : raw)
    }
    @State private var remindersPath: [ReminderTarget] = []
    /// The day Today shows. Picking a day in Calendar opens it here.
    @State private var todayDay: Date
    @State private var todayReferenceNow: Date
    /// The full-screen Chat page. A fresh one is built hidden ahead of time (after launch and after each Close), so a
    /// tap on the bottom field only reveals it; nil until the first one is built.
    @State private var ask: AskRoute?
    @State private var askVisible = false
    @State private var showsSearch = false
    @State private var newItem: NewItem?
    @State private var showsSettings = false
    @State private var showsActivity = false
    /// The left drawer (conversation history). See `Drawer.swift` for how the drag works.
    @State private var drawer = DrawerModel()
    /// A list screen is pushed inside Reminders; its back swipe owns the left edge.
    @State private var remindersPushed = false
    @State private var toast = UndoToast()
    @State private var tidying: TidyRoute?
    #if DEBUG
      @State private var shareImportTestState = ""
    #endif
    @Environment(\.undoManager) private var undoManager
    /// Counts tab switches made by swiping; drives their haptic (pill taps already have one).
    @State private var tabSwipes = 0
    /// The keyboard is up (typing a new reminder inline, a list name, …): the floating bar steps aside instead of
    /// riding on top of the keyboard, where it would cover the row being edited and a tap would open Ask.
    @State private var keyboardUp = false

    public var body: some View {
      #if DEBUG
        let _ = StoreChurnProbe.countShellBody()
      #endif
      GeometryReader { geo in
        // The sidebar takes most of the width; the page slides aside and stays visible beside it.
        let full = geo.size.width
        let width = full * DrawerLayout.widthFraction
        ZStack(alignment: .leading) {
          if drawer.isBuilt {
            Sidebar(
              drawer: drawer, width: width,
              onNewChat: { openAsk(nil, fromSidebar: true) },
              onOpen: { openAsk($0, fromSidebar: true) },
              onSearch: {
                PerformanceTrace.shared.beginPage("search")
                showsSearch = true
              },
              onSettings: {
                PerformanceTrace.shared.beginPage("settings")
                showsSettings = true
              },
              onActivity: {
                PerformanceTrace.shared.beginPage("activity")
                showsActivity = true
              },
              close: { drawer.set(open: false) }
            )
            .frame(width: width)
            .accessibilityHidden(askVisible)
            .modifier(DrawerSidebarSlide(model: drawer, width: width))
          }

          main
            .accessibilityHidden(askVisible)
            .ignoresSafeArea(.keyboard, edges: askVisible ? .bottom : [])
            .background(Color(.systemBackground))
            // Swipe right from the left edge opens the sidebar. The edge strip sits above the
            // lists so it wins over row swipe actions; row swipes elsewhere stay free.
            .overlay(alignment: .leading) {
              if edgeSwipeEnabled {
                Color.clear
                  .frame(width: 24)
                  .contentShape(Rectangle())
                  .modifier(DrawerDrag(model: drawer, width: width, kind: .edgeStrip))
              }
            }
            .modifier(
              DrawerDrag(model: drawer, width: width, kind: .edgeOnly, enabled: edgeSwipeEnabled)
            )
            .modifier(
              DrawerMainSlide(
                model: drawer, width: width, size: geo.size, insets: geo.safeAreaInsets))

          // The visible strip of the page: a tap or a drag to the left closes the sidebar.
          if drawer.isOpen {
            Button {
              drawer.set(open: false)
            } label: {
              Color.clear
                .frame(width: full - width)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sidebar")
            .modifier(DrawerDrag(model: drawer, width: width, kind: .close))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .ignoresSafeArea()
          }
        }
      }
      .overlay {
        GeometryReader { geometry in
          if let route = ask {
            AskScreen(
              thread: route.thread, subject: route.subject, toast: toast, composition: composition,
              isPresented: askVisible,
              onClose: closeAsk,
              onMenu: openSidebarFromAsk,
              onBack: { _ in },
              onAdded: { capture in
                if capture.hasDay { calendarDay = capture.day }
              },
              onOpenDay: { day in
                closeAsk()
                drawer.set(open: false, animated: false)
                tab = .today
                todayDay = session.runtime.calendar.startOfDay(for: day)
              }
            )
            .id(route.id)
            .background(Color(.systemBackground).ignoresSafeArea())
            // Like the page under it, a swipe right from the left edge opens the sidebar.
            .overlay(alignment: .leading) {
              Color.clear
                .frame(width: 20)
                .contentShape(Rectangle())
                .simultaneousGesture(
                  DragGesture(minimumDistance: 20).onEnded { v in
                    if v.translation.width > 60, v.translation.width > 2 * abs(v.translation.height)
                    {
                      openSidebarFromAsk()
                    }
                  })
            }
            // A hidden page stays mounted below the screen, out of hit testing; AskView drops its header and editor.
            .offset(y: askVisible ? 0 : geometry.size.height + 640)
            .opacity(askVisible ? 1 : 0)
            .transaction { if !askVisible { $0.disablesAnimations = true } }
            .allowsHitTesting(askVisible)
            .accessibilityAddTraits(askVisible ? .isModal : [])
            .accessibilityHidden(!askVisible)
          }
        }
        .allowsHitTesting(askVisible)
      }
      .sheet(item: $editor) {
        PlannerEditor(destination: $0, toast: toast, composition: composition)
      }
      .sheet(isPresented: $showsSettings) {
        ShellSettings(diagnostics: diagnostics, composition: composition)
      }
      .sheet(isPresented: $showsActivity) {
        ActivityView(
          activity: session.activity, flush: { session.ledger.flush(context) },
          undo: { await session.actions.undo($0, context: context) })
      }
      .environment(toast)
      .environment(session.actions)
      .environment(presentation)
      .environment(\.askAbout, { openAsk(nil, subject: $0) })
      .defaultAppStorage(session.defaults)
      .environment(\.calendar, session.runtime.calendar)
      .environment(\.locale, session.runtime.locale)
      .environment(\.timeZone, session.runtime.calendar.timeZone)
      .onAppear { toast.undoManager = undoManager }
      .onChange(of: undoManager) { _, new in toast.undoManager = new }
      .task {
        // Build the sidebar shortly after launch (off the cold-start path) so the first swipe is smooth.
        try? await Task.sleep(for: .seconds(1.5))
        drawer.isBuilt = true
      }
    }

    /// Moves one tab left (-1) or right (+1), stopping at the ends. Used by `TabSwipe`.
    private func switchTab(by step: Int) {
      let all = HomeTab.allCases
      guard let i = all.firstIndex(of: tab) else { return }
      let next = i + step
      guard all.indices.contains(next) else { return }
      traceTabAction(to: all[next])
      tab = all[next]
      tabSwipes += 1
    }

    private var traceRoute: String {
      tab == .calendar ? "calendar.\(calendarMode.rawValue.lowercased())" : tab.rawValue
    }

    private func traceTabAction(to destination: HomeTab) {
      guard PerformanceTrace.enabled, destination != tab else { return }
      let target =
        destination == .calendar
        ? "calendar.\(calendarMode.rawValue.lowercased())" : destination.rawValue
      PerformanceTrace.shared.begin("\(traceRoute)_to_\(target)", destination: target)
    }

    private var tracedCalendarMode: Binding<CalendarView.Mode> {
      Binding(
        get: { calendarMode },
        set: { mode in
          if mode != calendarMode {
            let target = "calendar.\(mode.rawValue.lowercased())"
            PerformanceTrace.shared.begin("\(traceRoute)_to_\(target)", destination: target)
          }
          calendarMode = mode
        })
    }

    private var edgeSwipeEnabled: Bool { !(tab == .tasks && remindersPushed) }

    /// The bottom field and sidebar New chat start a new conversation; a sidebar row reopens that one.
    /// A new conversation uses the page built hidden ahead of time, so opening only reveals it.
    /// A chat about one item ("Ask AI" in its menu) is always a fresh page that carries the item.
    private func openAsk(
      _ thread: ChatThread?, subject: AskSubject? = nil, fromSidebar: Bool = false
    ) {
      PerformanceTrace.shared.beginPage("ai")
      // Opened from the sidebar, the sidebar stays underneath: Close goes back to it.
      if !fromSidebar { drawer.set(open: false, animated: false) }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        if thread != nil || subject != nil || ask == nil || ask?.used == true {
          ask = AskRoute(thread: thread, subject: subject)
        }
        ask?.used = true
        askVisible = true
      }
    }

    /// Back to the page. The conversation is already saved in the sidebar (from its first message); an unsent draft
    /// goes with it, since the next tap starts a new chat.
    private func closeAsk() {
      if PerformanceTrace.enabled { PerformanceTrace.shared.mark("chat.close_requested") }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { askVisible = false }
      // Once this page is off screen, build the next new chat hidden.
      Task {
        try? await Task.sleep(for: .milliseconds(350))
        prepareNewAsk()
      }
    }

    /// Builds a new, hidden Chat page unless an unused one is ready or Chat is on screen.
    private func prepareNewAsk() {
      guard !askVisible, ask == nil || ask?.used == true else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { ask = AskRoute(thread: nil) }
    }

    /// Chat's menu button: past chats are in the sidebar beside the page.
    private func openSidebarFromAsk() {
      closeAsk()
      drawer.set(open: true)
    }

    /// Reminders added from the Share sheet wait in the App Group (`ShareInbox`) until the app is active; they come in
    /// here as new reminders, with an Undo toast. UI tests leave the inbox alone unless they pass `-uiTestingShare <title>`,
    /// which puts one there first, or `-uiTestingShareInbox`, which reads what the real Share sheet left.
    private static var sharedTestItemQueued = false

    private func importShared() {
      let args = composition.arguments
      var inboxURL = ShareInbox.fileURL
      #if DEBUG
        let test = ShareImportUITesting(arguments: args)
        if let test { inboxURL = test.inboxURL }
      #endif
      if args.contains("-uiTesting"), !args.contains("-uiTestingShareInbox") {
        guard let i = args.firstIndex(of: "-uiTestingShare"), i + 1 < args.count else { return }
        if !Self.sharedTestItemQueued {
          Self.sharedTestItemQueued = true
          var item = SharedReminder(
            title: args[i + 1], note: "https://example.com", due: ShareInbox.due(for: .tomorrow))
          #if DEBUG
            if let test { item.id = test.id }
          #endif
          ShareInbox.append(item, at: inboxURL)
        }
      }
      // A separate context makes this transaction independent of unrelated, unsaved editor changes.
      // Autosave stays off: failure leaves only the durable inbox, never partially inserted tasks.
      let importing = ModelContext(context.container)
      importing.autosaveEnabled = false
      let listNames = ((try? context.fetch(FetchDescriptor<OneList>())) ?? []).map(\.name)
      let chosenList = Preferences.newReminderList(existing: listNames)
      let added: [OneTask]
      var acknowledge: ((Set<UUID>) -> Bool)? = nil
      #if DEBUG
        if test?.failAcknowledgment == true { acknowledge = { _ in false } }
      #endif
      do {
        let result = try ShareImport.run(
          at: inboxURL,
          committedIDs: {
            Set(try importing.fetch(FetchDescriptor<ShareImportReceipt>()).map(\.sharedID))
          },
          persist: { shared in
            let tasks = shared.map { s in
              let task = OneTask(title: s.title, note: s.note, due: s.due)
              if let chosenList { task.listName = chosenList }
              importing.insert(task)
              importing.insert(ShareImportReceipt(sharedID: s.id))
              return task
            }
            #if DEBUG
              // Explicit injection before save, not a spontaneous SwiftData failure.
              if test?.failSave == true { throw ShareImportUITesting.InjectedFailure.save }
            #endif
            try importing.save()
            return tasks.map(\.persistentModelID)
          }, acknowledge: acknowledge)
        added = result.added.compactMap { context.model(for: $0) as? OneTask }
        #if DEBUG
          shareImportTestState =
            test?.state(
              in: context.container, outcome: result.acknowledged ? "acknowledged" : "ack-failed")
            ?? ""
        #endif
      } catch {
        // Keep the original drafts for the next activation. Do not roll back the UI's context.
        #if DEBUG
          importing.rollback()
          shareImportTestState = test?.state(in: context.container, outcome: "save-failed") ?? ""
        #endif
        return
      }
      guard !added.isEmpty else { return }
      session.activity.record(ActivityEvents.shareImport(count: added.count))
      let entries = added.map {
        session.ledger.record(
          .created, task: $0, title: $0.title, after: LedgerFormat.time($0.due, none: ""),
          actor: .share,
          channel: .share, context: context)
      }
      toast.show(
        added.count == 1
          ? "Added “\(added[0].title)” from Share" : "Added \(added.count) reminders from Share"
      ) {
        // Receipts survive Undo, including when inbox acknowledgment failed.
        added.forEach { context.delete($0) }
        try? context.save()
        entries.forEach { session.ledger.recordUndo(of: $0, context: context) }
        #if DEBUG
          shareImportTestState = test?.state(in: context.container, outcome: "undone") ?? ""
        #endif
      }
    }

    /// UI tests only (`-uiTesting -uiTestingAddReminder <title>`): adds one reminder without typing it.
    private static func seedUITestReminder(_ context: ModelContext, arguments: [String]) {
      let args = arguments
      guard args.contains("-uiTesting"), let i = args.firstIndex(of: "-uiTestingAddReminder"),
        i + 1 < args.count
      else { return }
      context.insert(OneTask(title: args[i + 1]))
    }

    private var page: some View {
      VStack(spacing: 0) {
        topBar
          .modifier(TabSwipe(isEnabled: !drawer.isOpen, move: switchTab))
        Group {
          switch tab {
          case .today:
            DayAgenda(
              day: $todayDay, showsWeekStrip: false, openTask: { editor = .task($0) },
              openEvent: { editor = .local($0) }, openAlarm: { editor = .alarm($0) },
              openTimer: {
                clockSection = .timer
                tab = .clock
              }, actions: session.actions, calendar: session.calendar, timers: session.timers,
              reminders: session.reminders, ledger: session.ledger, travel: session.travel,
              presentation: presentation, openTidy: { tidying = TidyRoute(overdue: $0) })
          case .calendar:
            CalendarView(
              day: $calendarDay,
              mode: PerformanceTrace.enabled ? tracedCalendarMode : $calendarMode,
              calendar: session.calendar, actions: session.actions, ledger: session.ledger,
              alarms: session.alarms, onOpenTask: { editor = .task($0) },
              onOpenAlarm: { editor = .alarm($0) },
              onOpenDay: { picked in
                todayDay = picked
                tab = .today
              },
              onVisibleDays: { calendarShown = $0 })
          case .tasks:
            RemindersView(
              isPushed: $remindersPushed,
              path: $remindersPath.performanceAction { $0.isEmpty ? nil : "reminders.list" },
              sync: session.reminders, actions: session.actions, ledger: session.ledger,
              alarms: session.alarms, presentation: presentation,
              openSettings: composition.openSettings,
              requestAccess: {
                await FirstRun.reminders(
                  session.reminders, defaults: session.defaults, arguments: composition.arguments)
              })
          case .clock:
            AlarmsView(
              section: $clockSection, alarms: session.alarms, timers: session.timers,
              notifications: session.notifications, soundPreview: session.soundPreview,
              worldClock: composition.world, stopwatch: composition.stopwatch,
              now: session.runtime.now, defaults: session.defaults,
              arguments: composition.arguments, onAlarmCreated: composition.recordCreatedAlarm,
              showUndo: toast.show)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          if PerformanceTrace.enabled {
            PerformanceContentProbe(
              route: traceRoute, generation: PerformanceTrace.shared.generation,
              bootstrapComplete: PerformanceTrace.shared.bootstrapComplete)
          }
        }
      }
      .safeAreaInset(edge: .bottom) { if !keyboardUp { bottomBar } }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
      ) { _ in
        // Chat covers the page and owns its keyboard; the page does not re-lay out under it.
        if !askVisible, !KeyboardWarmup.isRunning { keyboardUp = true }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
      ) { _ in
        keyboardUp = false
      }
      .sensoryFeedback(.selection, trigger: tabSwipes)
      .sheet(isPresented: $showsSearch) {
        SearchView(calendar: session.calendar, defaults: session.defaults) { destination in
          PlannerEditor(destination: destination, toast: toast, composition: composition)
        }
      }
      .sheet(item: $tidying) { route in
        TidySheet(
          overdue: route.overdue, actions: session.actions, ledger: session.ledger,
          presentation: presentation, toast: toast)
      }
      .sheet(isPresented: $addingCity) {
        CityPicker(store: composition.world, now: session.runtime.now)
      }
      .sheet(item: $newItem) { item in
        switch item {
        case .task:
          QuickReminderSheet(
            listName: newReminderListName, usesPreferredList: newReminderUsesPreferredList,
            actions: session.actions, ledger: session.ledger, alarms: session.alarms,
            // Due-style quick add; editing a reminder opens TaskEditor
            activity: session.activity, presentation: presentation)
        case .event:
          EventEditor(
            day: tab == .calendar ? calendarDay : session.runtime.now(), calendar: session.calendar,
            actions: session.actions, ledger: session.ledger, alarms: session.alarms,
            presentation: presentation)
        case .alarm:
          AlarmEditor(
            alarms: session.alarms, soundPreview: session.soundPreview, runtime: session.runtime,
            defaults: session.defaults, onCreated: composition.recordCreatedAlarm
          ).performanceDestination("alarm.editor")
        }
      }
    }

    private var main: some View {
      page
        .task { await bootstrap() }
        .onAppear { LaunchTimer.markFirstFrame() }
        .overlay(alignment: .topLeading) {
          if PerformanceTrace.enabled {
            Text(PerformanceTrace.shared.report).font(.system(size: 1)).opacity(0.01)
              .accessibilityIdentifier("performance.trace")
              .accessibilityLabel(PerformanceTrace.shared.report)
              .allowsHitTesting(false)
          }
          // UI tests read the cold start time from this invisible label.
          if ProcessInfo.processInfo.arguments.contains("-uiTesting"),
            let ms = LaunchTimer.milliseconds
          {
            Text(String(ms)).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier(
              "coldStartMs"
            ).accessibilityLabel(String(ms))
          }
          #if DEBUG
            if composition.arguments.contains("-uiTestingStoreChurn") { StoreChurnProbe() }
            if composition.arguments.contains("-uiTestingSyncDump"),
              let sync = session.reminders as? RemindersSync
            {
              SyncDumpProbe(sync: sync)
            }
            if !shareImportTestState.isEmpty {
              Text(shareImportTestState).font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("shareImport.testState")
                .accessibilityLabel(shareImportTestState)
                .allowsHitTesting(false)
            }
          #endif
        }
        // Timers follow AlarmKit on every tab, so the Today row appears the moment one starts (also from Siri).
        .task { await session.timers.watch() }
        // Store observation lives in a child so a save doesn't re-run this whole shell (and the sheet over it).
        .background { ReminderSignatureObserver(session: session) }
        .background { FocusHydrationObserver(session: session) }
        .onChange(of: QuickAction.shared.pending, initial: true) { _, type in
          guard let type else { return }
          QuickAction.shared.pending = nil
          switch type {
          case "com.luworks.today.ask": openAsk(nil)
          case "com.luworks.today.newTask": presentNewItem(.task)
          case "com.luworks.today.newAlarm": presentNewItem(.alarm)
          case "com.luworks.today.newEvent": newEvent()
          default: break
          }
        }
        .onChange(of: tab) { previous, t in
          if t == .today {
            todayDay = session.runtime.refreshedTodayDay(
              todayDay, previousNow: todayReferenceNow, now: session.runtime.now())
          }
          if previous == .today || t == .today { todayReferenceNow = session.runtime.now() }
          session.defaults.set(t.rawValue, forKey: Self.tabKey)
          session.activity.record(ActivityEvents.screenOpen(t.rawValue))
        }
        .onChange(of: calendarMode) { _, m in
          session.defaults.set(m.rawValue, forKey: Self.calendarModeKey)
        }
        .onChange(of: clockSection) { _, s in
          session.defaults.set(s.rawValue, forKey: Self.clockSectionKey)
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            todayDay = session.runtime.refreshedTodayDay(
              todayDay, previousNow: todayReferenceNow, now: session.runtime.now())
            todayReferenceNow = session.runtime.now()
            if PerformanceTrace.enabled, PerformanceTrace.shared.launchComplete {
              // Covered roots cannot prove the visible page resumed. Keep those samples absent.
              if !askVisible, !showsSettings, !showsActivity, !showsSearch, newItem == nil,
                !addingCity, !drawer.isOpen, remindersPath.isEmpty
              {
                PerformanceTrace.shared.begin("resume_to_content_layout", destination: traceRoute)
              } else {
                PerformanceTrace.shared.mark("skip.resume_covered_root")
              }
            }
            dropDeletedMirrors()
            importShared()
            session.activity.importOutbox()
            session.timers.refresh()
            Task { await session.notifications.resync() }
          }
          if phase == .background {
            session.ledger.flush(context)
            session.activity.flushInBackground()
            updateWidgets()
            session.widget.scheduleBackgroundRefresh()
          }
        }
        // An event deleted in Apple Calendar must not linger here: when the system calendar changes, drop the copies it lost.
        .onChange(of: session.calendar.version) {
          dropDeletedMirrors()
          updateWidgets()
        }
        // Widget rows link here (today://today?day=…): open Today on that day.
        .onOpenURL { url in
          guard let day = WidgetLink.day(from: url) else { return }
          closeAsk()
          showsSearch = false
          drawer.set(open: false, animated: false)
          tab = .today
          todayDay = day
        }
    }

    private func bootstrap() async {

      if PerformanceTrace.enabled { PerformanceTrace.shared.mark("bootstrap_start") }
      if let prepareData {
        guard await prepareData(context) else { return }
      }
      // Live starts empty. Only an injected development composition may prepare fixtures.
      ListActions.ensureLists(in: context, runtime: session.runtime)
      #if DEBUG
        // UI-test hooks on the simulator's own calendar (see CalendarSync and ios/README.md).
        let args = composition.arguments
        if let i = args.firstIndex(of: "-debugDeleteSystemEvent"), i + 1 < args.count {
          (session.calendar as? CalendarSync)?.debugDeleteSystemEvents(titled: args[i + 1])
        }
        if let i = args.firstIndex(of: "-debugCreateSystemEvent"), i + 1 < args.count {
          (session.calendar as? CalendarSync)?.debugCreateSystemEvent(
            titled: args[i + 1], repeating: false)
        }
        if let i = args.firstIndex(of: "-debugCreateRepeatingEvent"), i + 1 < args.count {
          (session.calendar as? CalendarSync)?.debugCreateSystemEvent(
            titled: args[i + 1], repeating: true)
        }
      #endif
      Self.seedUITestReminder(context, arguments: composition.arguments)
      importShared()
      session.activity.importOutbox()
      session.ledger.prune(now: session.runtime.now())
      await FirstRun.calendar(
        session.calendar, defaults: session.defaults, arguments: composition.arguments)
      if PerformanceTrace.enabled { PerformanceTrace.shared.finishBootstrap() }
      // Off the cold-start path, build the Chat page hidden so even the first tap only reveals it.
      try? await Task.sleep(for: .milliseconds(250))
      prepareNewAsk()
      // The first keyboard of the process is slow to load; load it now so the first Chat tap is as quick as later ones.
      if !askVisible, editor == nil, newItem == nil, !showsSearch, !showsSettings, !showsActivity,
        !addingCity
      {
        KeyboardWarmup.run()
      }
    }

    /// Rewrites the Lock Screen / Home Screen widget snapshot (skipped when nothing changed).
    private func updateWidgets() {
      ReminderSignatureObserver.updateWidgets(session: session, context: context)
    }

    private func dropDeletedMirrors() {
      let gone = session.calendar.removedMirrors(
        (try? context.fetch(FetchDescriptor<OneEvent>())) ?? [])
      guard !gone.isEmpty else { return }
      for event in gone {
        session.ledger.record(
          .deleted, kind: "event", title: event.title, before: DayLabel.withTime(event.start),
          actor: .agent("Apple Calendar"), channel: .sync, approval: .observed, context: context)
        context.delete(event)
      }
      try? context.save()
    }

    // MARK: Top: avatar + tab pills

    private var topBar: some View {
      HStack(spacing: 8) {
        // The three lines open the sidebar (chat history and Search), like ChatGPT and Claude; a swipe from the left edge does too.
        CircleButton(
          systemImage: "line.3.horizontal", label: "Open menu",
          size: ButtonConfiguration.minimumHitSize
        ) {
          drawer.set(open: true)
        }
        // Reserve the current month before adapting the pills. Keep their hit areas intact.
        HStack(spacing: 8) {
          ViewThatFits(in: .horizontal) {
            pills
            ScrollView(.horizontal, showsIndicators: false) { pills }
          }
          Spacer(minLength: 0)
          if !askVisible {
            TimelineView(.periodic(from: presentation.now, by: 60)) { _ in
              monthLabel
            }
            .id(headerTimeRevision)
            .layoutPriority(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      // Chrome stays usable at the largest text sizes; content below still scales fully.
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @State private var headerTimeRevision = 0

    /// All tabs name the device's current month, independently of the browsed day.
    private var monthLabel: some View {
      Text(
        MonthLabel.text(
          now: presentation.now, calendar: presentation.calendar,
          locale: presentation.locale)
      )
      .font(.footnote.weight(.semibold))
      .foregroundStyle(Color(.secondaryLabel))
      .lineLimit(1)
      .fixedSize()
      .accessibilityLabel(
        MonthLabel.text(
          now: presentation.now, length: .full,
          calendar: presentation.calendar, locale: presentation.locale)
      )
      .accessibilityIdentifier("topBar.month")
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
      ) { _ in
        headerTimeRevision += 1
      }
      .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
        headerTimeRevision += 1
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { headerTimeRevision += 1 }
      }
    }

    private var pills: some View {
      HStack(spacing: PillStyle.spacing) {
        ForEach(HomeTab.allCases.filter { $0 != .today }) { item in
          TabPill(tab: item, isSelected: item == tab) {
            traceTabAction(to: item)
            tab = item
          }
        }
      }
    }

    // MARK: Bottom: Today, Chat, new

    private var bottomBar: some View {
      VStack(spacing: 8) {
        // While the sidebar is open it shows its own toast: never two Undo buttons at once.
        if !drawer.isOpen { UndoToastView() }
        bottomButtons
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .contentShape(Rectangle())
          .modifier(TabSwipe(isEnabled: !drawer.isOpen, move: switchTab))
      }
      // Scroll content can extend beneath the safe-area inset. Keep it out of the controls.
      .background(Color(.systemBackground))
      .overlay(alignment: .top) {
        LinearGradient(
          colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
          startPoint: .top, endPoint: .bottom
        )
        .frame(height: 24)
        .offset(y: -24)
        .allowsHitTesting(false)
      }
    }

    /// A new event: Apple's own editor when Calendar access is on (presented by UIKit, see `NativeEvents`), else ours.
    private func newEvent() {
      guard session.calendar.usesNativeEditor else {
        presentNewItem(.event)
        return
      }
      guard let native = session.calendar as? any NativeCalendarService else {
        presentNewItem(.event)
        return
      }
      native.edit(
        identifier: nil,
        start: EventEditor.defaultStart(
          for: tab == .calendar ? calendarDay : session.runtime.now(), now: session.runtime.now(),
          calendar: session.runtime.calendar), end: nil, onComplete: nil)
    }

    /// On World Clock, + adds a city.
    private var plusAddsCity: Bool { tab == .clock && clockSection == .worldClock }

    /// A chat field that fills the bar, then Today and + on the right.
    private var bottomButtons: some View {
      HStack(spacing: 10) {
        Button {
          openAsk(nil)
        } label: {
          Text("Ask AI or add anything")
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(
              maxWidth: .infinity, minHeight: ButtonConfiguration.minimumHitSize,
              alignment: .leading
            )
            .padding(.horizontal, 16)
            .background(ButtonConfiguration.Icon.background, in: Capsule())
            .overlay { Capsule().strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Chat")
        // Keep the existing automation entry while giving VoiceOver the visible control's name.
        .accessibilityIdentifier("Ask AI or add anything")
        .accessibilityHint("Starts a new chat. Past chats are in the menu.")
        // Always today itself: from another tab, and from another day on the Today tab.
        Button {
          traceTabAction(to: .today)
          todayDay = session.runtime.calendar.startOfDay(for: session.runtime.now())
          tab = .today
        } label: {
          todayLabel(selected: tab == .today && !askVisible)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Today")
        .accessibilityAddTraits(tab == .today && !askVisible ? .isSelected : [])
        plusButton
      }
      .padding(.horizontal, 16)
      .padding(.top, 6)
      .padding(.bottom, 4)
    }

    /// The word "Today", like Apple Calendar's button: a capsule as tall as +.
    @AppStorage(TodayButtonColor.storageKey) private var todayButtonColor = TodayButtonColor.green
      .stored
    @Environment(\.colorScheme) private var identityColorScheme

    private func todayLabel(selected: Bool) -> some View {
      let fill = TodayButtonColor(stored: todayButtonColor).color
      return
        Text("Today")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(fill.contrastForeground(for: identityColorScheme))
        .padding(.horizontal, 14)
        .frame(
          minWidth: ButtonConfiguration.minimumHitSize,
          minHeight: ButtonConfiguration.minimumHitSize
        )
        .background(
          fill,
          in: Capsule()
        )
        .overlay { Capsule().strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5) }
        .animation(reduceMotion ? nil : PillStyle.selectionAnimation, value: selected)
        .contentShape(Capsule())
    }

    private var newReminderUsesPreferredList: Bool {
      guard tab == .tasks, let target = remindersPath.last else { return true }
      if case .defaultList = target { return false }
      return true
    }

    /// Resolve the current list by identity so renaming a list cannot leave a stale name behind.
    private var newReminderListName: String {
      guard tab == .tasks, let target = remindersPath.last, case .list(let id) = target,
        let list = context.model(for: id) as? OneList
      else { return "" }
      return list.name
    }

    private func presentNewItem(_ item: NewItem) {
      let route: String
      switch item {
      case .task: route = "reminder.quick"
      case .event: route = "event.editor"
      case .alarm: route = "alarm.editor"
      }
      PerformanceTrace.shared.beginPage(route)
      newItem = item
    }

    private var plusLabel: some View {
      Image(systemName: "plus")
        .font(ButtonConfiguration.Icon.font)
        .foregroundStyle(.primary)
        .frame(
          width: ButtonConfiguration.minimumHitSize, height: ButtonConfiguration.minimumHitSize
        )
        .background(ButtonConfiguration.Icon.background, in: Circle())
        .overlay { Circle().strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5) }
        .contentShape(Circle())
    }

    private var creationChoices: some View {
      Group {
        if plusAddsCity {
          Button {
            PerformanceTrace.shared.beginPage("clock.cityPicker")
            addingCity = true
          } label: {
            Label("Add city", systemImage: "globe")
          }
        }
        Button {
          presentNewItem(.alarm)
        } label: {
          Label("New alarm", systemImage: "alarm")
        }
        Button {
          presentNewItem(.task)
        } label: {
          Label("New reminder", systemImage: "checklist")
        }
        Button {
          newEvent()
        } label: {
          Label("New event", systemImage: "calendar")
        }
      }
    }

    /// + is the same menu on every page (alarm, reminder, event; plus Add city on World Clock), so what it
    /// offers never depends on where you are.
    private var plusButton: some View {
      Menu {
        Section(tab == .today ? "Add to Today" : "Add an item") { creationChoices }
      } label: {
        plusLabel
      }
      .tint(.primary)
      .accessibilityIdentifier("New")
      .accessibilityLabel(tab == .today ? "Add to Today" : "Add an item")
      .accessibilityHint("Choose an alarm, reminder or event.")
    }

  }

  /// Swipe left or right to move to the next or previous tab.
  ///
  /// Where it works: only on the top bar (the tab pills) and the bottom bar (Today, Chat, +). These two
  /// strips hold no rows, so they never compete with row swipe actions (Delete / Flag on reminders,
  /// alarms and events), with Calendar's own month/week paging, or with scrolling in the middle of the
  /// page. The middle of the page does not switch tabs on purpose.
  /// What it ignores: drags that start within 44pt of the left edge (they open the sidebar), drags that
  /// are not clearly sideways (horizontal under 2x vertical), and short ones. A drag on a button cancels
  /// its tap, so swiping across "Ask AI" does not open it.
  struct TabSwipe: ViewModifier {
    var isEnabled: Bool
    /// -1 = previous tab (finger moves right), +1 = next tab (finger moves left).
    let move: (Int) -> Void

    func body(content: Content) -> some View {
      content.simultaneousGesture(
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
          .onEnded { v in
            guard isEnabled, v.startLocation.x > 44 else { return }
            let dx = v.translation.width
            let dy = v.translation.height
            guard abs(dx) > 2 * abs(dy) else { return }
            // A quick flick counts even if the finger only moved a little.
            let reach =
              abs(v.predictedEndTranslation.width) > abs(dx) ? v.predictedEndTranslation.width : dx
            guard abs(reach) > 60 else { return }
            move(reach < 0 ? 1 : -1)
          })
    }
  }

  /// What the AI screen opens on. A fresh id per conversation, so a new chat always starts clean.
  /// Today's overdue reminders waiting in the Tidy sheet.
  struct TidyRoute: Identifiable {
    let id = UUID()
    let overdue: [OneTask]
  }

  struct AskRoute: Identifiable {
    let id = UUID()
    let thread: ChatThread?
    /// The item this chat was opened about, from an item's "Ask AI" menu row.
    var subject: AskSubject? = nil
    /// Shown at least once: the next new chat needs a new page.
    var used = false
  }

  enum NewItem: Identifiable {
    case task, event, alarm
    var id: Self { self }

    var noun: String {
      switch self {
      case .task: "a reminder"
      case .event: "an event"
      case .alarm: "an alarm"
      }
    }
  }

  /// Selected tab: a wide pill with its label. Others: icon-only capsules.
  struct TabPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: HomeTab
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
      Button(action: action) {
        HStack(spacing: PillStyle.Tab.iconLabelSpacing) {
          Image(systemName: tab.icon)
          if isSelected { Text(tab.title) }
        }
        .font(PillStyle.Tab.font)
        .padding(.horizontal, isSelected ? PillStyle.Tab.selectedPadding : 0)
        .frame(minWidth: PillStyle.Tab.minWidth, minHeight: PillStyle.Tab.height)
        .background(PillStyle.fill(selected: isSelected), in: Capsule())
        .foregroundStyle(PillStyle.text(selected: isSelected))
        .animation(reduceMotion ? nil : PillStyle.selectionAnimation, value: isSelected)
      }
      .buttonStyle(PressScale())
      .accessibilityLabel(tab.title)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }

  #if DEBUG
    /// Isolates the inbox beside a named UI-test store. No real App Group data is read or cleared.
    private struct ShareImportUITesting {
      let id: UUID
      let title: String
      let inboxURL: URL
      let failAcknowledgment: Bool
      let failSave: Bool

      enum InjectedFailure: Error { case save }

      init?(arguments args: [String]) {
        func value(_ flag: String) -> String? {
          guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
          return args[i + 1]
        }
        guard args.contains("-uiTesting"), let store = value("-uiTestingStore"),
          let rawID = value("-uiTestingShareID"), let id = UUID(uuidString: rawID),
          let title = value("-uiTestingShareProbeTitle")
        else { return nil }
        self.id = id
        self.title = title
        inboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(
          "\(store).share-inbox.json")
        failAcknowledgment = args.contains("-uiTestingShareFailAcknowledgment")
        failSave = args.contains("-uiTestingShareFailSave")
      }

      @MainActor
      func state(in container: ModelContainer, outcome: String) -> String {
        // Read committed rows through a fresh context, rather than the UI's pending inserts/deletes.
        let saved = ModelContext(container)
        do {
          let tasks = try saved.fetch(FetchDescriptor<OneTask>()).filter { $0.title == title }.count
          let receipts = try saved.fetch(FetchDescriptor<ShareImportReceipt>()).filter {
            $0.sharedID == id
          }.count
          let pending = try ShareInbox.read(at: inboxURL).filter { $0.id == id }.count
          return "\(outcome);tasks=\(tasks);receipts=\(receipts);pending=\(pending)"
        } catch { return "probe-failed" }
      }
    }
  #endif

#endif

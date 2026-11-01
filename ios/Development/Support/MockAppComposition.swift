#if TODAY_MOCK
  import Foundation
  import SwiftData
  import EventKit
  import One
  import TodayCore
  import TodayData
  import TodayShared
  import TodayPlatform
  import TodayDesignSystem
  import TodayTestSupport
  import TodayShell
  import FeatureClock
  import FeatureAsk

  /// Synthetic app lifecycle used only by the separate developer executable.
  @MainActor
  struct MockAppComposition {
    let shell: ShellComposition
    let services: PlannerTestServices

    init(arguments: [String]) throws {
      let defaults = UserDefaults.standard
      LaunchTestConfiguration.applyPreferenceOverrides(arguments: arguments, defaults: defaults)
      Appearance.applyConfiguration(
        LaunchTestConfiguration.appearanceOverride(arguments: arguments), defaults: defaults)
      let cal = Calendar.current
      let fixedNow = Self.value("-uiTestingNow", arguments).flatMap { raw -> Date? in
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: .now)
      }
      let runtime = PlannerRuntime(
        now: { fixedNow ?? Date.now }, nextID: { UUID() }, calendar: cal, locale: .current)
      let configuration: ModelConfiguration
      let activityStore: ActivityStore?
      if let name = Self.value("-uiTestingStore", arguments) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        configuration = ModelConfiguration(url: base.appendingPathExtension("store"))
        activityStore = try ActivityStore(
          location: .file(base.appendingPathExtension("activity.sqlite")))
      } else {
        configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        activityStore = nil
      }
      let container = try ModelContainer(
        for: OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, Habit.self,
        ChatThread.self, LedgerEntry.self, AIGrant.self, ShareImportReceipt.self,
        configurations: configuration)
      let services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime,
        arguments: arguments, activityStore: activityStore)
      try LaunchTestConfiguration.applyActivityOverrides(
        arguments: arguments, defaults: defaults, store: services.activityStore, now: runtime.now())
      self.services = services
      let calendar: any CalendarService
      let reminders: any ReminderService
      if arguments.contains("-uiTestingCalendarSync") || arguments.contains("-seedCalendarDemo") {
        calendar = CalendarSync(
          defaults: defaults, runtime: runtime, arguments: arguments, makeStore: { EKEventStore() })
      } else {
        calendar = services.calendar
      }
      if arguments.contains("-uiTestingRemindersSync") {
        let native = RemindersSync(
          defaults: defaults, runtime: runtime, arguments: arguments, makeStore: { EKEventStore() })
        reminders = native
      } else {
        reminders = services.reminders
      }
      let ledger = Ledger(activity: services.activity, reminders: reminders, runtime: runtime)
      if let native = reminders as? RemindersSync { native.configure(container, ledger: ledger) }
      let actions = PlannerActions(
        calendar: calendar, reminders: reminders, alarms: services.alarms, ledger: ledger,
        runtime: runtime, defaults: defaults)
      let widget = WidgetFeed(
        container: container, calendar: calendar, reminders: reminders, runtime: runtime,
        enabled: false, travel: { _, _, _, _, _ in nil }, save: { _ in false }, reload: {})
      let session = PlannerSession(
        container: container, defaults: defaults, runtime: runtime, calendar: calendar,
        reminders: reminders, alarms: services.alarms, timers: services.timers,
        notifications: services.notifications,
        activity: services.activity, ledger: ledger, actions: actions, travel: services.travel,
        soundPreview: services.soundPreview, widget: widget,
        inbox: FileShareInbox(url: ShareInbox.fileURL)
      ) {
        (calendar as? CalendarSync)?.dispose()
        (reminders as? RemindersSync)?.dispose()
        ledger.dispose()
        services.dispose()
      }
      let cities = try CityDatabase.decode(
        Data(contentsOf: Bundle.main.url(forResource: "cities", withExtension: "json")!))
      if arguments.contains("-uiTesting") {
        defaults.removeObject(forKey: WorldClockStore.defaultsKey)
        defaults.removeObject(forKey: StopwatchState.defaultsKey)
        defaults.removeObject(forKey: StopwatchPage.defaultsKey)
      }
      let homeZone =
        Self.value("-uiTestingHomeZone", arguments) ?? runtime.calendar.timeZone.identifier
      let home = Self.value("-uiTestingHomeCity", arguments).flatMap { cities.city(forKey: $0) }
      let keys = Self.value("-uiTestingCities", arguments).map {
        $0.split(separator: ",").map(String.init)
      }
      let world = WorldClockStore(
        database: cities, defaults: defaults, homeZoneIdentifier: homeZone,
        homeCity: home, initialKeys: keys ?? (arguments.contains("-uiTesting") ? [] : nil))
      var initialState: StopwatchState? = arguments.contains("-uiTesting") ? StopwatchState() : nil
      if let raw = Self.value("-uiTestingStopwatch", arguments), let seconds = Double(raw) {
        let laps =
          Self.value("-uiTestingStopwatchLaps", arguments)?.split(separator: ",").compactMap {
            Double($0)
          } ?? []
        initialState = StopwatchState(
          startedAt: nil, accumulated: seconds + laps.reduce(0, +), laps: laps)
      }
      let page =
        Self.value("-uiTestingStopwatchPage", arguments).flatMap(StopwatchPage.init(rawValue:))
        ?? (arguments.contains("-uiTesting") ? .analog : nil)
      let stopwatch = StopwatchModel(
        defaults: defaults, now: runtime.now, initialState: initialState, initialPage: page)
      let multiCapture = arguments.contains("-uiTestingMultiCapture")
      let askReplyDelay = arguments.contains("-uiTestingAskReplyDelay")
      let intelligence = AskIntelligence(
        backend: { multiCapture || askReplyDelay ? .scripted : .rules },
        parse: { text, _, now, calendar in
          if askReplyDelay { try? await Task.sleep(for: .seconds(12)) }
          return AskIntelligence.ruleCapture(text, now: now, calendar: calendar)
        },
        propose: { text, _, now, calendar in
          guard multiCapture, text.contains(";") else { return nil }
          return text.split(separator: ";").map {
            CaptureParser.parse(
              String($0).trimmingCharacters(in: .whitespaces), now: now, calendar: calendar)
          }
        }, refineTitle: { capture, _, _ in capture },
        respond: { text, _, intent in
          if askReplyDelay, intent != .capture { try? await Task.sleep(for: .seconds(12)) }
          return intent == .capture ? .capture : .reply(ChatRouting.fallbackReply(text))
        },
        plan: { _, _, _, _, _ in EditPlan(op: .none, target: nil) },
        rank: { _, _, _, _ in nil }, prewarm: {}, isAvailable: { multiCapture || askReplyDelay },
        unavailableReason: { _ in "Unavailable on Simulator" })
      shell = ShellComposition(
        session: session, world: world, stopwatch: stopwatch, intelligence: intelligence,
        agentModel: AgentScripts.model(Self.value("-uiTestingAgentScript", arguments)),
        voice: VoiceInput(driver: MockSpeechDriver()), arguments: arguments, openSettings: {})
    }

    private static func value(_ flag: String, _ arguments: [String]) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }
  }

  @MainActor
  private final class MockSpeechDriver: SpeechInputDriving {
    func start(
      onTranscript: @escaping @MainActor (String) -> Void,
      onState: @escaping @MainActor (VoiceInput.State) -> Void
    ) async { onState(.unavailable) }
    func stop() {}
  }
#endif

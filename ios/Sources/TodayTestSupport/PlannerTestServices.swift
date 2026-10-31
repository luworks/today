#if os(iOS)
  import Foundation
  import Observation
  import SwiftData
  import SwiftUI
  import EventKit  // EKSpan is a value required by the compatibility contract; no store is created.
  import UserNotifications  // Authorization values only; no notification center is created.
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import One

  /// Development-only composition. The caller owns the container, runtime and isolated defaults lifetime.
  @MainActor
  package final class PlannerTestServices {
    package let container: ModelContainer
    package let defaults: UserDefaults
    package let runtime: PlannerRuntime
    package let calendar: TestCalendarService
    package let reminders: TestReminderService
    package let alarms: TestAlarmService
    package let timers: TestTimerService
    package let notifications: TestNotificationService
    package let travel: TestTravelTimes
    package let soundPreview: TestSoundPreview
    package let activityStore: ActivityStore
    package let activity: ActivityCenter
    package let ledger: Ledger
    package let actions: PlannerActions
    package private(set) var isDisposed = false

    /// A memory SQLite open can fail; surface it instead of silently dropping Activity recording.
    package init(
      container: ModelContainer, defaults: UserDefaults, runtime: PlannerRuntime,
      arguments: [String], activityStore suppliedActivityStore: ActivityStore? = nil
    ) throws {
      self.container = container
      self.defaults = defaults
      self.runtime = runtime
      calendar = TestCalendarService(runtime: runtime)
      reminders = TestReminderService(runtime: runtime, arguments: arguments)
      alarms = TestAlarmService()
      alarms.failsSchedule = arguments.contains("-uiTestingAlarmScheduleError")
      alarms.failsCancel = arguments.contains("-uiTestingAlarmCancelError")
      if arguments.contains("-uiTestingAlarmDenied") {
        alarms.authorization = .denied
        alarms.authorizationResponse = .denied
      }
      timers = TestTimerService(defaults: defaults, runtime: runtime, arguments: arguments)
      notifications = TestNotificationService()
      travel = TestTravelTimes(runtime: runtime)
      soundPreview = TestSoundPreview()
      activityStore = try suppliedActivityStore ?? ActivityStore(location: .memory)
      activity = ActivityCenter(store: activityStore, defaults: defaults, runtime: runtime)
      ledger = Ledger(activity: activity, reminders: reminders, runtime: runtime)
      actions = PlannerActions(
        calendar: calendar, reminders: reminders, alarms: alarms,
        ledger: ledger, runtime: runtime, defaults: defaults)
    }

    /// Cancel view-owned tasks/toasts first. Remove defaults only after this method returns.
    package func dispose() {
      guard !isDisposed else { return }
      calendar.dispose()
      reminders.dispose()
      alarms.dispose()
      timers.dispose()
      notifications.dispose()
      soundPreview.stop()
      ledger.dispose()
      activity.dispose()
      isDisposed = true
    }
  }

  /// Local-only calendar. Even enabled fixtures never offer an EventKit editor or external writes.
  @MainActor @Observable
  package final class TestCalendarService: CalendarService {
    package var version = 0
    package var isReady = true
    package var hasAccess = false
    package var enabled = false
    package var isDisposed = false
    package var lastError: String?
    package var isQuerying = false
    package var availableCalendars: [SystemCalendar] = []
    package var queryEvents: [ExternalEvent] = []
    package var hiddenCalendarIDs: Set<String> = []
    package private(set) var refreshCount = 0
    package private(set) var deletionRequests: [String?] = []
    package var deletionResult: Bool?
    package private(set) var enableRequests: [Bool] = []
    private let runtime: PlannerRuntime
    package init(runtime: PlannerRuntime) { self.runtime = runtime }
    package var isOn: Bool { enabled && hasAccess && !isDisposed }
    package var usesNativeEditor: Bool { false }
    package func prepare() { if !isDisposed { isReady = true } }
    package func prepareStore() { prepare() }
    package func connectIfFirstRun() async { prepare() }
    package func setEnabled(_ on: Bool) async {
      guard !isDisposed else { return }
      enableRequests.append(on)
      enabled = on
      hasAccess = on
      version += 1
    }
    package func refresh() {
      guard !isDisposed else { return }
      refreshCount += 1
      version += 1
    }
    package func calendars() -> [SystemCalendar] { isOn ? availableCalendars : [] }
    package func setVisibleCalendars(_ selected: Set<String>) {
      hiddenCalendarIDs = Set(availableCalendars.map(\.id)).subtracting(selected)
      version += 1
    }
    package func events(in interval: DateInterval, excluding: Set<String>) -> [ExternalEvent] {
      guard isOn, isReady, !isQuerying, lastError == nil else { return [] }
      return queryEvents.filter {
        !excluding.contains($0.eventIdentifier) && !hiddenCalendarIDs.contains($0.calendarID)
          && $0.start < interval.end && $0.end > interval.start
      }
    }
    package func events(on day: Date, excluding: Set<String>) -> [ExternalEvent] {
      guard let interval = runtime.calendar.dateInterval(of: .day, for: day) else { return [] }
      return events(in: interval, excluding: excluding)
    }
    private func event(_ id: String?) -> ExternalEvent? {
      guard isOn, let id else { return nil }
      return queryEvents.first { $0.eventIdentifier == id }
    }
    package var focusResolutions: [String: FocusIdentityResolution] = [:]
    package func focusIdentity(externalID: String?, occurrence: Date?) -> FocusIdentityResolution {
      guard let id = externalID else { return .localOnly }
      return focusResolutions[id] ?? .unavailable
    }
    package func cachedFocusIdentity(externalID: String?, occurrence: Date?)
      -> FocusIdentityResolution
    {
      focusIdentity(externalID: externalID, occurrence: occurrence)
    }
    package func hydrateFocus(_ records: [FocusRecord]) async {}
    package func cachedEvent(externalID: String, occurrence: Date?) -> ExternalEvent? {
      queryEvents.first {
        $0.eventIdentifier == externalID && (occurrence == nil || $0.start == occurrence)
      }
    }
    package func cachedCanDelete(externalID: String?) -> Bool { canDelete(externalID: externalID) }
    package func calendar(forExternalID id: String?) -> SystemCalendar? {
      guard let e = event(id) else { return nil }
      return availableCalendars.first { $0.id == e.calendarID }
    }
    package func place(forExternalID id: String?) -> TravelPlace? { event(id)?.place }
    package func color(forExternalID id: String?) -> Color? { event(id)?.color }
    package func isHidden(externalID: String?) -> Bool {
      guard let e = event(externalID) else { return false }
      return hiddenCalendarIDs.contains(e.calendarID)
    }
    package func isRepeating(externalID: String?) -> Bool { event(externalID)?.repeats ?? false }
    package func audience(externalID: String?) -> (attendees: Int, isOrganizer: Bool)? { nil }
    package func canDelete(externalID: String?) -> Bool {
      guard !isDisposed else { return false }
      guard let externalID else { return true }
      return writableExternalIDs.contains(externalID)
    }
    /// Explicit fixtures for linked-event writes. Empty by default: no external write is accepted.
    package var writableExternalIDs: Set<String> = []
    /// Explicit `save` results; nil keeps the default refusal.
    @ObservationIgnored package var saveResult: ((OneEvent) -> String?)?
    package private(set) var saveRequests: [String?] = []
    /// Explicit system-move fixtures; nil keeps the default `CalendarMoveError.unavailable`.
    @ObservationIgnored package var moveSnapshotResult:
      ((String, Date) throws -> CalendarMoveSnapshot)?
    @ObservationIgnored package var moveEventResult:
      ((CalendarMoveSnapshot, Date) throws -> CalendarMoveOutcome)?
    @ObservationIgnored package var undoMoveResult:
      ((CalendarMoveReceipt) throws -> CalendarMoveUndoOutcome)?
    package var creationFailure: CalendarCreationError?
    package var defaultCalendarID: String?
    package private(set) var creationCalendarIDs: [String] = []
    package func create(_ event: OneEvent, calendarID: String? = nil) throws
      -> CalendarCreationReceipt
    {
      guard event.externalID == nil else { throw CalendarCreationError.existingEvent }
      guard !enabled || isOn else { throw CalendarCreationError.unavailable }
      return try CalendarCreation.commit(
        calendarID: calendarID, connected: isOn,
        resolve: { id in
          guard let id = id ?? self.defaultCalendarID else { return nil as SystemCalendar? }
          return self.availableCalendars.first { $0.id == id }
        },
        writable: { $0.allowsContentModifications },
        save: { destination in
          if let failure = self.creationFailure { throw failure }
          self.creationCalendarIDs.append(destination.id)
          self.version += 1
          return "test-event-\(event.id)"
        })
    }
    // A fake never silently claims a system move succeeded without an explicit fixture.
    package func moveSnapshot(externalID: String, occurrence: Date) throws -> CalendarMoveSnapshot {
      guard !isDisposed, let fixture = moveSnapshotResult else {
        throw CalendarMoveError.unavailable
      }
      return try fixture(externalID, occurrence)
    }
    package func moveEvent(
      expected: CalendarMoveSnapshot, to start: Date, acknowledgingAudience: Bool
    ) throws -> CalendarMoveOutcome {
      guard !isDisposed, let fixture = moveEventResult else { throw CalendarMoveError.unavailable }
      return try fixture(expected, start)
    }
    package func undoMove(_ receipt: CalendarMoveReceipt, acknowledgingAudience: Bool) throws
      -> CalendarMoveUndoOutcome
    {
      guard !isDisposed, let fixture = undoMoveResult else { throw CalendarMoveError.unavailable }
      return try fixture(receipt)
    }
    package func save(_ event: OneEvent, span: EKSpan) -> String? {
      guard !isDisposed, let fixture = saveResult else { return nil }
      saveRequests.append(event.externalID)
      return fixture(event)
    }
    package func delete(_ event: OneEvent, span: EKSpan) -> Bool {
      delete(externalID: event.externalID, occurrence: event.start, span: span)
    }
    package func delete(externalID: String?, occurrence: Date?, span: EKSpan) -> Bool {
      deletionRequests.append(externalID)
      return deletionResult ?? canDelete(externalID: externalID)
    }
    package func removedMirrors(_ events: [OneEvent]) -> [OneEvent] { [] }
    package func title(externalID: String, occurrence: Date?) -> String? {
      event(externalID)?.title
    }
    package func rename(externalID: String, occurrence: Date?, to title: String) -> Bool { false }
    package func dispose() {
      isDisposed = true
      enabled = false
      hasAccess = false
      version += 1
    }
  }

  @MainActor @Observable
  package final class TestReminderService: ReminderService {
    package struct CompletionCall {
      package let taskID: PersistentIdentifier
      package let externalID: String?
      package let done: Bool
      package let restoringDue: Date?
      package let restoresDue: Bool
      package let expected: RemindersSync.Remote?
    }
    package enum Failure: LocalizedError {
      case injected, disconnected, changedOutside
      package var errorDescription: String? {
        switch self {
        case .injected: "The reminder could not be saved (test failure)."
        case .disconnected: "The test reminder service is disconnected."
        case .changedOutside: "The test reminder changed outside this session."
        }
      }
    }
    package var hasAccess = false
    package var isConnected = false
    package var isDenied = false
    package var lastError: String?
    package var isReconciling = false
    package var connectionGranted = true
    package var completionFailure: Failure?
    package var completionReceipt: RemindersSync.Remote?
    package var currentRemote: RemindersSync.Remote?
    package private(set) var completionCalls: [CompletionCall] = []
    package private(set) var persistedCompletions: [PersistentIdentifier] = []
    package private(set) var deletedReminderIDs: [String?] = []
    package private(set) var deletedListIDs: [String?] = []
    package private(set) var reconcileDelays: [Duration] = []
    package private(set) var reconcileCount = 0
    package private(set) var connectCount = 0
    package private(set) var isDisposed = false
    private let runtime: PlannerRuntime
    package init(runtime: PlannerRuntime, arguments: [String]) {
      self.runtime = runtime
      if arguments.contains("-uiTestingFailReminderCompletion") { completionFailure = .injected }
      failCreationOnce = arguments.contains("-uiTestingFailReminderCreationOnce")
    }
    package func connectIfFirstRun() async {}  // No implicit authorization in local sessions.
    package func connect() async {
      guard !isDisposed else { return }
      connectCount += 1
      hasAccess = connectionGranted
      isConnected = connectionGranted
      isDenied = !connectionGranted
    }
    package func disconnect() {
      isConnected = false
      hasAccess = false
    }
    package func forgetLink() {
      disconnect()
      currentRemote = nil
      completionReceipt = nil
    }
    package func noteDeleted(reminder externalID: String?) { deletedReminderIDs.append(externalID) }
    package func noteDeleted(list externalID: String?) { deletedListIDs.append(externalID) }
    package func scheduleReconcile(after delay: Duration) {
      guard !isDisposed else { return }
      reconcileDelays.append(delay)
    }
    package func reconcile() async {
      guard !isDisposed else { return }
      reconcileCount += 1
    }
    private var failCreationOnce = false
    package var creationFailure: Failure?
    package private(set) var creationCalls = 0
    package func commitCreation(_ task: OneTask, context: ModelContext) throws {
      creationCalls += 1
      if failCreationOnce {
        failCreationOnce = false
        throw Failure.injected
      }
      if let creationFailure { throw creationFailure }
      // This synthetic adapter never manufactures an EventKit identity.
      context.insert(task)
      do { try context.save() } catch {
        context.delete(task)
        throw error
      }
    }
    package var editFailure: Failure?
    package var deletionFailure: Failure?
    package private(set) var editCalls = 0
    package private(set) var deletionCalls = 0

    package var focusResolutions: [String: FocusIdentityResolution] = [:]
    package func focusIdentity(_ task: OneTask) -> FocusIdentityResolution {
      guard let id = task.externalID else { return .localOnly }
      return focusResolutions[id] ?? .unavailable
    }
    package func commitEdit(_ task: OneTask, draft: TaskSnapshot, expected: TaskSnapshot) throws
      -> RemindersSync.Remote?
    {
      guard let id = task.externalID else { return nil }
      guard isConnected else { throw Failure.disconnected }
      editCalls += 1
      if let editFailure { throw editFailure }
      if let currentRemote, currentRemote.fingerprint != RemindersSync.fingerprint(of: expected) {
        throw Failure.changedOutside
      }
      let accepted = RemindersSync.Remote(
        id: id, title: draft.title, notes: draft.note,
        isDone: draft.isDone, doneAt: draft.doneAt, due: draft.due, listID: "test-list",
        listTitle: draft.listName, flagged: draft.flagged, repeatRule: draft.repeatRule,
        repeats: draft.repeatRule != nil)
      currentRemote = accepted
      return accepted
    }
    package func didPersistEdit(_ task: OneTask, accepted: RemindersSync.Remote?) {
      scheduleReconcile(after: .milliseconds(50))
    }
    package func commitDeletion(_ task: OneTask, expected: TaskSnapshot) throws
      -> ReminderDeletionReceipt
    {
      guard let id = task.externalID else { return .localOnly }
      guard isConnected else { throw Failure.disconnected }
      deletionCalls += 1
      if let deletionFailure { throw deletionFailure }
      guard let currentRemote else { return .alreadyAbsent(id) }
      guard currentRemote.fingerprint == RemindersSync.fingerprint(of: expected) else {
        throw Failure.changedOutside
      }
      self.currentRemote = nil
      return .confirmed(currentRemote, token: runtime.nextID())
    }
    package func restoreDeletion(_ task: OneTask, receipt: ReminderDeletionReceipt) throws
      -> RemindersSync.Remote?
    {
      switch receipt {
      case .localOnly: return nil
      case .alreadyAbsent: throw Failure.changedOutside
      case .confirmed:
        guard isConnected else { throw Failure.disconnected }
        guard currentRemote == nil else { throw Failure.changedOutside }
        let restored = RemindersSync.Remote(
          id: runtime.nextID().uuidString, title: task.title,
          notes: task.note, isDone: task.isDone, doneAt: task.doneAt, due: task.due,
          listID: "test-list", listTitle: task.listName, flagged: task.flagged,
          repeatRule: task.repeatRule, repeats: task.repeatRule != nil)
        currentRemote = restored
        return restored
      }
    }
    package func commitCompletion(
      _ task: OneTask, done: Bool, restoringDue: Date?, restoresDue: Bool,
      expected: RemindersSync.Remote?
    ) throws -> RemindersSync.Remote? {
      completionCalls.append(
        CompletionCall(
          taskID: task.persistentModelID, externalID: task.externalID,
          done: done, restoringDue: restoringDue, restoresDue: restoresDue, expected: expected))
      // Local completion must remain usable without connecting a remote service.
      guard let id = task.externalID else { return nil }
      guard !isDisposed, isConnected, hasAccess else { throw Failure.disconnected }
      if let completionFailure {
        lastError = completionFailure.localizedDescription
        throw completionFailure
      }
      if let expected {
        guard let currentRemote, currentRemote.id == expected.id,
          currentRemote.fingerprint == expected.fingerprint,
          currentRemote.doneAt == expected.doneAt
        else { throw Failure.changedOutside }
      }
      let receipt =
        completionReceipt
        ?? RemindersSync.Remote(
          id: id, title: task.title, notes: task.note,
          isDone: done, doneAt: done ? runtime.now() : nil,
          due: restoresDue ? restoringDue : task.due, listID: "test-list", listTitle: task.listName,
          flagged: task.flagged, repeatRule: task.repeatRule, repeats: task.repeatRule != nil)
      currentRemote = receipt
      lastError = nil
      return receipt
    }
    package func didPersistCompletion(_ task: OneTask, restoredDue: Bool) {
      persistedCompletions.append(task.persistentModelID)
      scheduleReconcile(after: .milliseconds(50))
    }
    package func dispose() {
      isDisposed = true
      disconnect()
    }
  }

  @MainActor @Observable
  package final class TestAlarmService: AlarmService {
    package var authorization: AlarmAuthorization = .authorized
    package var states: [UUID: AlarmLiveState] = [:]
    package var authorizationResponse: AlarmAuthorization = .authorized
    package var isAvailable = true
    package private(set) var requestCount = 0
    package private(set) var syncCount = 0
    package var failsSchedule = false
    package var failsCancel = false
    package private(set) var scheduledIDs: [UUID] = []
    package private(set) var cancelledIDs: [UUID] = []
    private var committing = false
    package private(set) var stoppedIDs: [UUID] = []
    package private(set) var isDisposed = false
    package init() {}
    package func state(of alarm: OneAlarm) -> AlarmLiveState? {
      alarm.alarmKitID.flatMap { states[$0] }
    }
    package func requestAuthorization() async {
      guard !isDisposed else { return }
      requestCount += 1
      authorization = authorizationResponse
    }
    package func sync(_ context: ModelContext) async { if !isDisposed { syncCount += 1 } }
    package func commit(_ alarm: OneAlarm, context: ModelContext) async throws {
      guard !committing, !isDisposed else { throw AlarmActions.Failure.busy }
      committing = true
      defer { committing = false }
      try await AlarmActions.persist(
        alarm, context: context,
        schedule: { proposal in
          guard self.authorization == .authorized, !self.failsSchedule else {
            throw AlarmActions.Failure.unavailable
          }
          if let id = proposal.alarmKitID {
            self.scheduledIDs.append(id)
            self.states[id] = proposal.isOn ? .scheduled : nil
          }
        }, cancel: { proposal in try self.cancel(proposal) })
    }
    package func cancel(_ alarm: OneAlarm) throws {
      guard !isDisposed, !failsCancel, authorization == .authorized else {
        throw AlarmActions.Failure.unavailable
      }
      if let id = alarm.alarmKitID {
        cancelledIDs.append(id)
        states[id] = nil
      }
    }
    package func stop(_ id: UUID) {
      guard !isDisposed else { return }
      stoppedIDs.append(id)
      states[id] = nil
    }
    package func watch(context: ModelContext) async { await sync(context) }
    package func dispose() { isDisposed = true }
  }

  @MainActor @Observable
  package final class TestTimerService: TimerService {
    package private(set) var timers: [RunningTimer]
    package private(set) var ringing: Set<UUID> = []
    package private(set) var log: PomodoroLog
    package private(set) var recents: [RecentTimer]
    package var sound: String { didSet { defaults.set(sound, forKey: "timer.sound") } }
    package var message: String?
    /// Optional explicit fake system projection. Nil derives local countdown/paused/ringing states.
    package var liveStates: [UUID: LiveTimerState]?
    package private(set) var startsByHand: [Bool] = []
    package private(set) var isDisposed = false
    private let defaults: UserDefaults
    private let runtime: PlannerRuntime
    private let isUITesting: Bool
    private let freezesLegacyFixtures: Bool

    package init(defaults: UserDefaults, runtime: PlannerRuntime, arguments: [String]) {
      self.defaults = defaults
      self.runtime = runtime
      isUITesting = arguments.contains("-uiTesting")
      freezesLegacyFixtures =
        arguments.contains("-uiTesting") || arguments.contains("-uiTestingTimers")
      timers = isUITesting ? [] : TimerStore.load(defaults)
      recents = isUITesting ? [] : TimerRecentsStore.load(defaults)
      sound = isUITesting ? "" : defaults.string(forKey: "timer.sound") ?? ""
      log =
        isUITesting
        ? .empty(runtime.now(), calendar: runtime.calendar)
        : PomodoroLog.load(defaults, now: runtime.now(), calendar: runtime.calendar)
      // Legacy fixture grammar from 81d020d, confined to this test-only factory.
      func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
      }
      if let seed = value("-uiTestingTimers") {
        timers = []
        for part in seed.split(separator: ",") {
          let fields = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
          guard let seconds = Int(fields[0]) else { continue }
          var timer = RunningTimer.start(
            id: runtime.nextID(), seconds: seconds, now: runtime.now(),
            label: fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil, source: .voice)
          if fields.contains("paused") { timer = timer.paused(now: runtime.now()) }
          if fields.contains("ringing") { ringing.insert(timer.id) }
          timers.append(timer)
        }
      }
      if let seed = value("-uiTestingRecents") {
        recents = seed.split(separator: ",").compactMap { part in
          let fields = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
          guard let seconds = Int(fields[0]) else { return nil }
          return RecentTimer(seconds: seconds, label: fields.count > 1 ? fields[1] : nil)
        }
      }
      if let seed = value("-pomodoroRounds"), let n = Int(seed) {
        log = .empty(runtime.now(), calendar: runtime.calendar)
        log.rounds = n
        log.pending = n > 0 ? .focus : nil
      }
    }
    package func start(seconds: Int, label: String?, byHand: Bool) async -> RunningTimer? {
      guard !isDisposed, seconds > 0 else { return nil }
      message = nil
      let seconds = min(seconds, TimerDial.maxSeconds)
      let label = IntentTimer.label(label)
      let phase = Pomodoro.preset(seconds: seconds, label: label)
      if phase != nil { updateLog { $0.pending = nil } }
      let timer = RunningTimer.start(
        id: runtime.nextID(), seconds: seconds, now: runtime.now(),
        phase: phase ?? .focus, label: label, source: phase == nil ? .voice : .card)
      let next = TimerList.adding(timer, to: timers)
      ringing.formIntersection(Set(next.map(\.id)))
      set(next)
      startsByHand.append(byHand)
      recents = TimerRecents.recording(RecentTimer(seconds: seconds, label: label), in: recents)
      if !isUITesting { TimerRecentsStore.save(recents, defaults) }
      return timer
    }
    package func pause(_ id: UUID) {
      guard !isDisposed, let t = timers.first(where: { $0.id == id }), !t.isPaused else { return }
      replace(t.paused(now: runtime.now()))
    }
    package func resume(_ id: UUID) {
      guard !isDisposed, let t = timers.first(where: { $0.id == id }), t.isPaused else { return }
      replace(t.resumed(now: runtime.now()))
    }
    package func cancel(_ id: UUID) {
      guard !isDisposed, let t = timers.first(where: { $0.id == id }) else { return }
      if ringing.contains(id), t.isCard { complete(t) }
      ringing.remove(id)
      liveStates?[id] = nil
      set(timers.filter { $0.id != id })
    }
    package func deleteRecent(id: String) {
      guard !isDisposed else { return }
      recents = TimerRecents.removing(id: id, from: recents)
      if !isUITesting { TimerRecentsStore.save(recents, defaults) }
    }
    package func refresh() {
      guard !isDisposed else { return }
      updateLog { _ in }
      // Legacy UI fixtures stay frozen until explicitly projected by a test.
      if freezesLegacyFixtures, liveStates == nil { return }
      let live =
        liveStates
        ?? Dictionary(
          uniqueKeysWithValues: timers.map {
            (
              $0.id,
              ringing.contains($0.id) || $0.ranToEnd(now: runtime.now())
                ? LiveTimerState.ringing
                : ($0.isPaused ? .paused : .running)
            )
          })
      let result = TimerList.reconcile(local: timers, live: live, now: runtime.now())
      for timer in result.finished where timer.isCard { complete(timer) }
      ringing = result.ringing
      set(result.timers)
    }
    package func watch() async { refresh() }  // No driver, observer or background task.
    private func complete(_ timer: RunningTimer) {
      updateLog {
        $0 = $0.completing(
          timer.pomodoroPhase, id: timer.id,
          now: runtime.now(), calendar: runtime.calendar)
      }
    }
    private func updateLog(_ change: (inout PomodoroLog) -> Void) {
      var next = log.current(runtime.now(), calendar: runtime.calendar)
      change(&next)
      if next != log {
        log = next
        PomodoroLog.save(next, defaults)
      }
    }
    private func replace(_ timer: RunningTimer) {
      set(timers.map { $0.id == timer.id ? timer : $0 })
    }
    private func set(_ next: [RunningTimer]) {
      timers = next
      if !isUITesting { TimerStore.save(next, defaults) }
    }
    package func dispose() { isDisposed = true }
  }

  @MainActor @Observable
  package final class TestNotificationService: NotificationService {
    package var status: UNAuthorizationStatus = .authorized
    package var permissionResponse = true
    package private(set) var requestCount = 0
    package private(set) var resyncCount = 0
    package private(set) var isDisposed = false
    package init() {}
    package func authorizationStatus() async -> UNAuthorizationStatus { status }
    package func requestPermission() async -> Bool {
      guard !isDisposed else { return false }
      requestCount += 1
      status = permissionResponse ? .authorized : .denied
      return permissionResponse
    }
    package func resync() async { if !isDisposed { resyncCount += 1 } }
    package func dispose() { isDisposed = true }
  }

  @MainActor @Observable
  package final class TestTravelTimes: TravelTimeProviding {
    package var version = 0
    package var cache: [String: TravelEstimate] = [:] { didSet { version += 1 } }
    package var enabled = true { didSet { version += 1 } }
    private let runtime: PlannerRuntime
    package init(runtime: PlannerRuntime) { self.runtime = runtime }
    package func seconds(
      eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date,
      askPermission: Bool
    ) -> TimeInterval? {
      guard enabled, let place, !eventID.isEmpty,
        TravelTime.isEligible(
          start: start, isAllDay: isAllDay, location: place.address, now: now,
          calendar: runtime.calendar)
      else { return nil }
      return TravelTime.usable(
        cache[
          TravelTime.cacheKey(
            eventID: eventID, start: start, address: place.address, calendar: runtime.calendar)])
    }
    package func label(eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date)
      -> String?
    {
      guard
        let seconds = seconds(
          eventID: eventID, start: start, isAllDay: isAllDay, place: place,
          now: now, askPermission: false)
      else { return nil }
      return TravelTime.label(start: start, travelSeconds: seconds, now: now) {
        let formatter = DateFormatter()
        formatter.calendar = self.runtime.calendar
        formatter.locale = self.runtime.locale
        formatter.timeZone = self.runtime.calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: $0)
      }
    }
    package func widgetFields(
      eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date
    ) -> (minutes: Int, leaveBy: Date)? {
      guard
        let seconds = seconds(
          eventID: eventID, start: start, isAllDay: isAllDay, place: place,
          now: now, askPermission: false)
      else { return nil }
      return (TravelTime.minutes(seconds), TravelTime.leaveBy(start: start, travelSeconds: seconds))
    }
  }

  @MainActor @Observable
  package final class TestSoundPreview: SoundPreviewing {
    package private(set) var selectedName: String?
    package private(set) var playedNames: [String] = []
    package private(set) var stopCount = 0
    package init() {}
    package func play(_ sound: AlarmSound) {
      selectedName = sound.name
      playedNames.append(sound.name)
    }
    package func stop() {
      selectedName = nil
      stopCount += 1
    }
  }
#endif

#if os(iOS)
  import Foundation
  import SwiftUI
  import SwiftData
  import EventKit
  import EventKitUI
  import UserNotifications
  import TodayCore
  import TodayShared
  import TodayData

  /// Model-bound compatibility contracts. Implementations are selected by executable composition.
  /// Persistent declarations remain in One; no feature resolves a live service implicitly.
  @MainActor
  package protocol CalendarService: AnyObject {
    var version: Int { get }
    var isReady: Bool { get }
    var hasAccess: Bool { get }
    var isOn: Bool { get }
    var usesNativeEditor: Bool { get }
    var hiddenCalendarIDs: Set<String> { get }
    func prepare()
    func prepareStore()
    func connectIfFirstRun() async
    func setEnabled(_ on: Bool) async
    func refresh()
    func calendars() -> [SystemCalendar]
    func setVisibleCalendars(_ selected: Set<String>)
    func events(in interval: DateInterval, excluding: Set<String>) -> [ExternalEvent]
    /// The same events, read off the main actor where the adapter can (a whole year for the Year view).
    func loadEvents(in interval: DateInterval, excluding: Set<String>) async -> [ExternalEvent]
    func events(on day: Date, excluding: Set<String>) -> [ExternalEvent]
    func focusIdentity(externalID: String?, occurrence: Date?) -> FocusIdentityResolution
    /// Display-only import snapshots. These never query EventKit and never authorize a write.
    func cachedFocusIdentity(externalID: String?, occurrence: Date?) -> FocusIdentityResolution
    func hydrateFocus(_ records: [FocusRecord]) async
    func cachedEvent(externalID: String, occurrence: Date?) -> ExternalEvent?
    func cachedCanDelete(externalID: String?) -> Bool
    func calendar(forExternalID id: String?) -> SystemCalendar?
    func place(forExternalID id: String?) -> TravelPlace?
    func color(forExternalID id: String?) -> Color?
    func isHidden(externalID: String?) -> Bool
    func isRepeating(externalID: String?) -> Bool
    func audience(externalID: String?) -> (attendees: Int, isOrganizer: Bool)?
    func canDelete(externalID: String?) -> Bool
    /// Creates only after explicit user confirmation. nil selects the default calendar.
    /// Throws on any connected save failure; never falls back from an explicit destination.
    /// Does not insert/save the local model or mutate its externalID; callers persist the receipt.
    func create(_ event: OneEvent, calendarID: String?) throws -> CalendarCreationReceipt
    func save(_ event: OneEvent, span: EKSpan) -> String?
    func delete(_ event: OneEvent, span: EKSpan) -> Bool
    func delete(externalID: String?, occurrence: Date?, span: EKSpan) -> Bool
    func removedMirrors(_ events: [OneEvent]) -> [OneEvent]
    func title(externalID: String, occurrence: Date?) -> String?
    func rename(externalID: String, occurrence: Date?, to title: String) -> Bool
    /// Read live state before presenting a user-confirmed move. Never authorizes a write by itself.
    func moveSnapshot(externalID: String, occurrence: Date) throws -> CalendarMoveSnapshot
    func moveEvent(expected: CalendarMoveSnapshot, to start: Date, acknowledgingAudience: Bool)
      throws
      -> CalendarMoveOutcome
    func undoMove(_ receipt: CalendarMoveReceipt, acknowledgingAudience: Bool) throws
      -> CalendarMoveUndoOutcome
  }

  /// Native EventKit UI is an explicit live capability, absent from deterministic sessions.
  @MainActor
  package protocol NativeCalendarService: CalendarService {
    var eventStore: EKEventStore { get }
    func nativeEvent(identifier: String, occurrence: Date?) -> (EKEvent, EKEventStore)?
    func edit(
      identifier: String?, start: Date, end: Date?, fullOptions: Bool,
      onComplete: ((EKEventEditViewAction) -> Void)?)
  }

  package enum ReminderDeletionReceipt {
    case localOnly
    case confirmed(RemindersSync.Remote, token: UUID)
    case alreadyAbsent(String)
  }

  @MainActor
  package protocol ReminderService: AnyObject {
    var hasAccess: Bool { get }
    var isConnected: Bool { get }
    var isDenied: Bool { get }
    var lastError: String? { get }
    func connectIfFirstRun() async
    func connect() async
    func disconnect()
    func forgetLink()
    func noteDeleted(reminder externalID: String?)
    func noteDeleted(list externalID: String?)
    func scheduleReconcile(after delay: Duration)
    func reconcile() async
    /// A submitted clear one-off request. Returns only after system and local saves succeed.
    /// The caller retains the same detached task on failure so a retry keeps its system identity.
    func commitCreation(_ task: OneTask, context: ModelContext) throws
    func focusIdentity(_ task: OneTask) -> FocusIdentityResolution
    func commitEdit(_ task: OneTask, draft: TaskSnapshot, expected: TaskSnapshot) throws
      -> RemindersSync.Remote?
    func didPersistEdit(_ task: OneTask, accepted: RemindersSync.Remote?)
    func commitDeletion(_ task: OneTask, expected: TaskSnapshot) throws -> ReminderDeletionReceipt
    func restoreDeletion(_ task: OneTask, receipt: ReminderDeletionReceipt) throws -> RemindersSync
      .Remote?
    func commitCompletion(
      _ task: OneTask, done: Bool, restoringDue: Date?, restoresDue: Bool,
      expected: RemindersSync.Remote?
    ) throws -> RemindersSync.Remote?
    func didPersistCompletion(_ task: OneTask, restoredDue: Bool)
  }

  @MainActor
  package protocol AlarmService: AnyObject {
    var authorization: AlarmAuthorization { get }
    var states: [UUID: AlarmLiveState] { get }
    var isAvailable: Bool { get }
    func state(of alarm: OneAlarm) -> AlarmLiveState?
    func requestAuthorization() async
    func sync(_ context: ModelContext) async
    /// MainActor only. Commits an attached edited alarm (or a detached new alarm) to
    /// AlarmKit, then saves its model. Failure restores the prior saved values and
    /// attempts system compensation; a compensation failure is reported explicitly.
    func commit(_ alarm: OneAlarm, context: ModelContext) async throws
    /// Cancels only this app's stable AlarmKit ID. Does not delete or save the model.
    func cancel(_ alarm: OneAlarm) throws
    func stop(_ id: UUID)
    func watch(context: ModelContext) async
  }

  @MainActor
  package protocol TimerService: AnyObject {
    var timers: [RunningTimer] { get }
    var ringing: Set<UUID> { get }
    var log: PomodoroLog { get }
    var recents: [RecentTimer] { get }
    var sound: String { get set }
    var message: String? { get }
    func start(seconds: Int, label: String?, byHand: Bool) async -> RunningTimer?
    func pause(_ id: UUID)
    func resume(_ id: UUID)
    func cancel(_ id: UUID)
    func deleteRecent(id: String)
    func refresh()
    func watch() async
  }

  @MainActor
  package protocol NotificationService: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestPermission() async -> Bool
    func resync() async
  }

  // Convenience arguments preserve call semantics while always dispatching to the injected instance.
  extension CalendarService {
    /// The shared display/Open lookup; an opaque anchor alone never identifies a source item.
    package func cachedFocusEvent(identity: FocusIdentity, reference: String?) -> ExternalEvent? {
      guard let reference, reference.hasPrefix("eventkit:") else { return nil }
      let id = String(reference.dropFirst("eventkit:".count))
      guard
        cachedFocusIdentity(externalID: id, occurrence: identity.occurrence)
          == .available(identity)
      else { return nil }
      return cachedEvent(externalID: id, occurrence: identity.occurrence)
    }
    package func events(in interval: DateInterval) -> [ExternalEvent] {
      events(in: interval, excluding: [])
    }
    package func loadEvents(in interval: DateInterval, excluding: Set<String>) async
      -> [ExternalEvent]
    {
      events(in: interval, excluding: excluding)
    }
    package func events(on day: Date) -> [ExternalEvent] { events(on: day, excluding: []) }
    package func save(_ event: OneEvent) -> String? { save(event, span: .futureEvents) }
    package func delete(_ event: OneEvent) -> Bool { delete(event, span: .futureEvents) }
    package func delete(externalID: String?, occurrence: Date? = nil) -> Bool {
      delete(externalID: externalID, occurrence: occurrence, span: .futureEvents)
    }
  }
  extension ReminderService {
    package func scheduleReconcile() { scheduleReconcile(after: .milliseconds(1200)) }
    package func commitCompletion(
      _ task: OneTask, done: Bool, restoringDue: Date? = nil,
      restoresDue: Bool = false
    ) throws -> RemindersSync.Remote? {
      try commitCompletion(
        task, done: done, restoringDue: restoringDue, restoresDue: restoresDue, expected: nil)
    }
    package func didPersistCompletion(_ task: OneTask) {
      didPersistCompletion(task, restoredDue: false)
    }
  }
  extension TimerService {
    @discardableResult
    package func start(seconds: Int, label: String? = nil) async -> RunningTimer? {
      await start(seconds: seconds, label: label, byHand: false)
    }
  }
#endif

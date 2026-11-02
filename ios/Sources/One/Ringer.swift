#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData
  import SwiftUI
  import CryptoKit
  import os
  #if canImport(AlarmKit)
    import AlarmKit
    import AppIntents
  #endif

  /// Real alarms (AlarmKit): full-screen, ring through Silent and Focus. Covers the alarms made on
  /// the Alarms tab (`OneAlarm`, one stable AlarmKit id each) and tasks/events marked "Ring as alarm".
  /// Stopping an alarm never completes the task; only Done does.
  ///
  /// What AlarmKit can and cannot do, so nobody expects more:
  /// - It lists only alarms THIS app scheduled. It cannot read, edit or delete alarms made in Apple's own
  ///   Clock app (or any other app). There is no API for that, and this file does not try to work around it.
  /// - It has no label for a scheduled alarm that the app can read back, so ids are the link between
  ///   `OneAlarm` and the system alarm.
  /// - The alert sound is the system default or a sound file bundled in the app; Apple's ringtones are not available.
  /// - Snooze is a secondary button with `.countdown` behaviour and a post-alert duration.
  @MainActor
  package final class Ringer {
    private let defaults: UserDefaults
    package let runtime: PlannerRuntime
    private let authorizationCache = AlarmAuthorizationCache()
    private var authorizationTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var schedulingTimers: Set<UUID> = []

    /// The one AlarmKit owner shared by AlarmCenter and TimerController in live composition.
    package init(defaults: UserDefaults, runtime: PlannerRuntime) {
      self.defaults = defaults
      self.runtime = runtime
      Task { [weak self] in await self?.refreshAuthorization() }
      #if canImport(AlarmKit)
        authorizationTask = Task { [weak self] in
          for await state in AlarmManager.shared.authorizationUpdates {
            guard !Task.isCancelled else { return }
            self?.receiveAuthorization(Self.authorization(state))
          }
        }
      #endif
      foregroundTask = Task { [weak self] in
        for await _ in NotificationCenter.default.notifications(
          named: UIApplication.willEnterForegroundNotification)
        {
          guard !Task.isCancelled else { return }
          await self?.refreshAuthorization()
        }
      }
    }

    deinit {
      foregroundTask?.cancel()
      authorizationTask?.cancel()
    }

    package func requireTimerDefaults(_ defaults: UserDefaults) {
      precondition(
        self.defaults === defaults,
        "TimerController and Ringer must share the same defaults instance")
    }

    package var timerIDs: Set<UUID> {
      Set(TimerStore.load(defaults).map(\.id)).union(schedulingTimers)
    }
    package func claimTimer(_ id: UUID) { schedulingTimers.insert(id) }
    package func releaseTimer(_ id: UUID) { schedulingTimers.remove(id) }

    #if canImport(AlarmKit)
      package nonisolated var manager: AlarmManager { AlarmManager.shared }
    #endif
    package var isAvailable: Bool { true }

    package var authorization: AlarmAuthorization { authorizationCache.state }
    package var isDenied: Bool { authorization == .denied }

    #if canImport(AlarmKit)
      package nonisolated static func authorization(_ state: AlarmManager.AuthorizationState)
        -> AlarmAuthorization
      {
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
      }
    #endif

    package func receiveAuthorization(_ state: AlarmAuthorization) {
      authorizationCache.receive(state)
    }

    private func refreshAuthorization() async {
      #if canImport(AlarmKit)
        await authorizationCache.refresh {
          await withCheckedContinuation { continuation in
            // AlarmManager is nonisolated in the SDK. Its getter may wait on synchronous XPC;
            // a dedicated dispatch work item keeps that wait off the main/cooperative executors.
            DispatchQueue.global(qos: .utility).async {
              continuation.resume(
                returning: Self.authorization(AlarmManager.shared.authorizationState))
            }
          }
        }
      #endif
    }

    /// Consume the returned decision directly; reading authorizationState here can deadlock after denial.
    package func requestAuthorization() async {
      #if canImport(AlarmKit)
        await authorizationCache.request {
          try await Self.authorization(manager.requestAuthorization())
        }
      #endif
    }

    // Syncs can be requested faster than they finish (edit, toggle, an AlarmKit update). They run one at a time,
    // and a request that arrives mid-run makes the running one go around again.
    private var isSyncing = false
    private var syncAgain = false

    /// Brings AlarmKit in line with the data, changing only what differs:
    /// - an alarm on the Alarms tab has its own id; it is scheduled, rescheduled (only if edited) or cancelled by that id,
    /// - a one-time alarm that AlarmKit no longer has (it rang and was stopped) is switched off in the list,
    /// - items marked "Ring as alarm" get an id derived from their title and time,
    /// - anything else this app scheduled earlier is cancelled, except an alarm that is ringing right now
    ///   and the countdown timers (`TimerStore`, see TimerController.swift).
    package func sync(_ context: ModelContext) async {
      #if canImport(AlarmKit)
        if isSyncing {
          syncAgain = true
          return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
          syncAgain = false
          await AlarmScheduler.reconcile(context, driver: self)
        } while syncAgain
      #endif
    }

    /// Explicit user writes share the reconciliation lock. A concurrent request
    /// fails visibly instead of racing an old reconciliation snapshot.
    package func commit(_ alarm: OneAlarm, context: ModelContext) async throws {
      guard !isSyncing else {
        if alarm.modelContext === context {
          let reader = ModelContext(context.container)
          if let saved = try reader.fetch(FetchDescriptor<OneAlarm>()).first(where: {
            $0.persistentModelID == alarm.persistentModelID
          }) {
            alarm.restoreSettings(from: saved)
          }
        }
        throw AlarmActions.Failure.busy
      }
      isSyncing = true
      defer {
        isSyncing = false
        if syncAgain {
          syncAgain = false
          Task { @MainActor in await self.sync(context) }
        }
      }
      try await AlarmActions.persist(
        alarm, context: context,
        schedule: { proposal in
          try await self.write(proposal)
        },
        cancel: { proposal in
          try self.cancelSystem(proposal)
        })
    }

    package func cancel(_ alarm: OneAlarm) throws {
      guard !isSyncing else { throw AlarmActions.Failure.busy }
      guard !alarm.isDeleted, let context = alarm.modelContext else {
        throw AlarmActions.Failure.stale
      }
      if let id = alarm.alarmKitID {
        let matches = try context.fetch(FetchDescriptor<OneAlarm>()).filter { $0.alarmKitID == id }
        guard matches.count == 1, matches.first === alarm else { throw AlarmActions.Failure.stale }
      }
      try cancelSystem(alarm)
    }

    private func cancelSystem(_ alarm: OneAlarm) throws {
      guard let id = alarm.alarmKitID else { return }
      #if canImport(AlarmKit)
        guard authorization == .authorized, !timerIDs.contains(id)
        else { throw AlarmActions.Failure.unavailable }
        // AlarmManager exposes only the current client's namespace.
        if try manager.alarms.contains(where: { $0.id == id }) { try manager.cancel(id: id) }
      #else
        throw AlarmActions.Failure.unavailable
      #endif
    }

    private func write(_ alarm: OneAlarm) async throws {
      #if canImport(AlarmKit)
        if authorization == .notDetermined { await requestAuthorization() }
        guard authorization == .authorized, let id = alarm.alarmKitID,
          !timerIDs.contains(id)
        else { throw AlarmActions.Failure.unavailable }
        let existing = try manager.alarms.first { $0.id == id }
        if let existing {
          // Editing must not silently stop a ringing/snoozing alarm.
          guard existing.state == .scheduled else { throw AlarmActions.Failure.busy }
          try manager.cancel(id: id)
        }
        if alarm.isOn {
          try await AlarmScheduler.scheduleThrowing(
            driver: self, id: id,
            title: alarm.label.isEmpty ? AlarmPlan.defaultLabel : alarm.label,
            schedule: AlarmScheduler.schedule(
              hour: alarm.hour, minute: alarm.minute, weekdays: alarm.weekdays),
            snooze: alarm.snooze, sound: alarm.sound, snoozeMinutes: alarm.snoozeMinutes,
            entity: EntityIdentifier(for: AlarmEntity.self, identifier: id))
        }
      #else
        throw AlarmActions.Failure.unavailable
      #endif
    }

    /// Stops a ringing alarm (the Stop button on the row). Never completes a task.
    package func stop(_ id: UUID) {
      #if canImport(AlarmKit)
        try? manager.stop(id: id)
      #endif
    }
  }

  #if canImport(AlarmKit)
    @MainActor
    package enum AlarmScheduler {
      typealias Meta = AlarmMeta

      package static let log = Logger(subsystem: "com.luworks.today", category: "alarms")

      /// A task or event that rings as an alarm.
      private struct ItemAlarm {
        let id: UUID
        let title: String
        let date: Date
      }

      package static func reconcile(_ context: ModelContext, driver: Ringer) async {
        let now = driver.runtime.now()
        let alarms = (try? context.fetch(FetchDescriptor<OneAlarm>())) ?? []
        let tasks =
          (try? context.fetch(
            FetchDescriptor<OneTask>(predicate: #Predicate { $0.ringsAsAlarm && !$0.isDone })))
          ?? []
        let events =
          (try? context.fetch(FetchDescriptor<OneEvent>(predicate: #Predicate { $0.ringsAsAlarm })))
          ?? []
        let due: [(String, Date)] =
          tasks.compactMap { t in
            plannerReminderDate(t, runtime: driver.runtime).map { (t.title, $0) }
          }
          + events.compactMap { e in
            plannerReminderDate(e, runtime: driver.runtime).map { (e.title, $0) }
          }
        let items = due.filter { $0.1 > now }.sorted { $0.1 < $1.1 }.prefix(30).map {
          ItemAlarm(id: stableID(title: $0.0, date: $0.1), title: $0.0, date: $0.1)
        }

        // A one-time alarm whose time has passed is done, whatever AlarmKit says (it also covers a denied state).
        for alarm in alarms where alarm.isOn && alarm.weekdays.isEmpty {
          if let fire = AlarmPlan.nextFire(
            hour: alarm.hour, minute: alarm.minute, weekdays: [],
            after: alarm.createdAt, calendar: driver.runtime.calendar), fire < now
          {
            alarm.isOn = false
          }
        }
        for alarm in alarms where alarm.alarmKitID == nil {
          alarm.alarmKitID = driver.runtime.nextID()
        }

        let manager = driver.manager
        let wantsAnything = alarms.contains(where: \.isOn) || !items.isEmpty
        log.info(
          "sync: \(alarms.count) alarm(s), \(items.count) item(s), auth \(String(describing: driver.authorization))"
        )
        if driver.authorization == .notDetermined, wantsAnything {
          await driver.requestAuthorization()
        }
        guard driver.authorization == .authorized else { return }

        var existing: [UUID: Alarm] = [:]
        for alarm in (try? manager.alarms) ?? [] { existing[alarm.id] = alarm }
        var keep = Set<UUID>()
        // The countdown timers (the Timer tab, and the ones made by voice) are not in the data; never cancel them as leftovers.
        keep.formUnion(driver.timerIDs)

        for alarm in alarms {
          guard let id = alarm.alarmKitID else { continue }
          if !alarm.isOn {
            if let live = existing[id], live.state != .alerting { try? manager.cancel(id: id) }
            alarm.alarmKitSignature = nil
            continue
          }
          keep.insert(id)
          let signature = alarm.scheduleSignature
          if let live = existing[id] {
            if alarm.alarmKitSignature == signature { continue }
            // Edited while it is ringing or snoozing: let it finish; the next AlarmKit update runs this again.
            if live.state == .alerting || live.state == .countdown { continue }
            try? manager.cancel(id: id)
          } else if alarm.alarmKitSignature != nil, alarm.weekdays.isEmpty {
            // We scheduled this one-time alarm, and AlarmKit no longer has it: it rang and was stopped.
            alarm.isOn = false
            alarm.alarmKitSignature = nil
            keep.remove(id)
            continue
          }
          let ok = await schedule(
            driver: driver, id: id,
            title: alarm.label.isEmpty ? AlarmPlan.defaultLabel : alarm.label,
            schedule: schedule(hour: alarm.hour, minute: alarm.minute, weekdays: alarm.weekdays),
            snooze: alarm.snooze, sound: alarm.sound, snoozeMinutes: alarm.snoozeMinutes,
            entity: EntityIdentifier(for: AlarmEntity.self, identifier: id))
          alarm.alarmKitSignature = ok ? signature : nil
        }

        for item in items {
          keep.insert(item.id)
          if existing[item.id] == nil {
            _ = await schedule(
              driver: driver, id: item.id, title: item.title, schedule: .fixed(item.date),
              snooze: false)
          }
        }

        // Leftovers: alarms deleted in the app, items that moved or finished, ids from older versions.
        keep.formUnion(driver.timerIDs)
        for (id, live) in existing where !keep.contains(id) && live.state != .alerting {
          try? manager.cancel(id: id)
          log.info("cancelled stale alarm")
        }
      }

      package static func schedule(hour: Int, minute: Int, weekdays: [Int]) -> Alarm.Schedule {
        let days = weekdays.compactMap(weekday)
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        return .relative(.init(time: time, repeats: days.isEmpty ? .never : .weekly(days)))
      }

      private static func weekday(_ n: Int) -> Locale.Weekday? {
        [
          1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday, 5: .thursday, 6: .friday,
          7: .saturday,
        ][n]
      }

      /// Same title and time always give the same id, so an unchanged item is never rescheduled.
      private static func stableID(title: String, date: Date) -> UUID {
        let digest = SHA256.hash(
          data: Data("item|\(title)|\(Int(date.timeIntervalSince1970))".utf8))
        let b = Array(digest.prefix(16))
        return UUID(
          uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
            b[14], b[15]
          ))
      }

      private static func schedule(
        driver: Ringer, id: UUID, title: String, schedule: Alarm.Schedule, snooze: Bool,
        sound: String = "", snoozeMinutes: Int = 9, entity: EntityIdentifier? = nil
      ) async -> Bool {
        do {
          try await scheduleThrowing(
            driver: driver, id: id, title: title, schedule: schedule,
            snooze: snooze, sound: sound, snoozeMinutes: snoozeMinutes, entity: entity)
          return true
        } catch {
          log.error("schedule failed \((error as NSError).code, privacy: .public)")
          return false
        }
      }

      /// `entity` ties an alarm from the Alarms tab to its Siri entity (`AlarmEntity`), so Siri knows which one rings.
      package static func scheduleThrowing(
        driver: Ringer, id: UUID, title: String, schedule: Alarm.Schedule, snooze: Bool,
        sound: String = "", snoozeMinutes: Int = 9, entity: EntityIdentifier? = nil
      ) async throws {
        let resource = LocalizedStringResource(stringLiteral: title)
        let snoozeButton = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let secondary = snooze ? snoozeButton : nil
        let behavior: AlarmPresentation.Alert.SecondaryButtonBehavior? = snooze ? .countdown : nil
        let alert = AlarmPresentation.Alert(
          title: resource, secondaryButton: secondary, secondaryButtonBehavior: behavior)
        // While snoozing, the countdown shows the alarm's title (what Clock shows under the snooze timer).
        let presentation = AlarmPresentation(
          alert: alert,
          countdown: snooze ? AlarmPresentation.Countdown(title: resource) : nil)
        let attributes = AlarmAttributes<Meta>(
          presentation: presentation, metadata: AlarmMeta(kind: .alarm), tintColor: .orange)
        let configuration = AlarmManager.AlarmConfiguration<Meta>(
          countdownDuration: snooze
            ? Alarm.CountdownDuration(
              preAlert: nil,
              postAlert: TimeInterval(AlarmPlan.snoozeMinutes(nearest: snoozeMinutes) * 60)) : nil,
          schedule: schedule,
          attributes: attributes,
          appEntityIdentifier: entity,
          // An alarm from the Clock tab records its Stop, so the day it rang shows it (`DayHistory`).
          stopIntent: entity == nil ? nil : AlarmStoppedIntent(alarmID: id, label: title),
          sound: AlarmSound.named(sound)?.alertSound ?? .default)
        _ = try await driver.manager.schedule(id: id, configuration: configuration)
      }
    }
  #endif
#endif

#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData
  import SwiftUI
  #if canImport(AlarmKit)
    import AlarmKit
  #endif

  /// What AlarmKit says an alarm is doing right now.
  package enum AlarmLiveState: Equatable {
    /// Waiting for its time.
    case scheduled
    /// Rang and the user tapped Snooze; it rings again when the countdown ends.
    case snoozing
    case paused
    /// Ringing right now.
    case ringing
  }

  /// Live view of the alarms this app has scheduled in AlarmKit, for the Alarms tab: which one is ringing,
  /// which one is snoozing, and whether the user allowed alarms.
  ///
  /// This is AlarmKit's real state, but only for alarms Today scheduled. AlarmKit gives no access to alarms
  /// made in Apple's Clock app.
  @MainActor
  @Observable
  package final class AlarmCenter: AlarmService {
    private let driver: Ringer
    package init(driver: Ringer) {
      self.driver = driver
    }
    package var isAvailable: Bool { driver.isAvailable }
    package func sync(_ context: ModelContext) async {
      await driver.sync(context)
      refreshStates()
    }
    package func commit(_ alarm: OneAlarm, context: ModelContext) async throws {
      try await driver.commit(alarm, context: context)
      refreshStates()
    }
    package func cancel(_ alarm: OneAlarm) throws {
      try driver.cancel(alarm)
      refreshStates()
    }
    package func stop(_ id: UUID) {
      driver.stop(id)
      refreshStates()
    }

    package var authorization: AlarmAuthorization { driver.authorization }
    /// Keyed by `OneAlarm.alarmKitID` (and the ids of items that ring as alarms).
    package private(set) var states: [UUID: AlarmLiveState] = [:]

    package func state(of alarm: OneAlarm) -> AlarmLiveState? {
      alarm.alarmKitID.flatMap { states[$0] }
    }

    package func requestAuthorization() async {
      await driver.requestAuthorization()
    }

    @MainActor
    private final class WatchSession {
      private let context: ModelContext
      private let driver: Ringer
      init(context: ModelContext, driver: Ringer) {
        self.context = context
        self.driver = driver
      }
      func synchronize() async {
        guard !Task.isCancelled else { return }
        await driver.sync(context)
      }
      #if canImport(AlarmKit)
        func watchAlarms(center: AlarmCenter) async {
          for await _ in driver.manager.alarmUpdates {
            guard !Task.isCancelled else { return }
            center.refreshStates()
            await synchronize()
          }
        }
        func watchAuthorization(center: AlarmCenter) async {
          for await state in driver.manager.authorizationUpdates {
            guard !Task.isCancelled else { return }
            driver.receiveAuthorization(Ringer.authorization(state))
            await synchronize()
            center.refreshStates()
          }
        }
      #endif
    }

    /// Follows AlarmKit until the calling task is cancelled (attach it to the view with `.task`).
    /// Every update also runs a sync, so a one-time alarm that rang is switched off in the list.
    package func watch(context: ModelContext) async {
      #if canImport(AlarmKit)
        refreshStates()
        let session = WatchSession(context: context, driver: driver)
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await session.watchAlarms(center: self) }
          group.addTask { await session.watchAuthorization(center: self) }
        }
      #endif
    }

    private func refreshStates() {
      #if canImport(AlarmKit)
        guard authorization == .authorized else {
          states = [:]
          return
        }
        var next: [UUID: AlarmLiveState] = [:]
        for alarm in (try? driver.manager.alarms) ?? [] {
          switch alarm.state {
          case .scheduled: next[alarm.id] = .scheduled
          case .countdown: next[alarm.id] = .snoozing
          case .paused: next[alarm.id] = .paused
          case .alerting: next[alarm.id] = .ringing
          @unknown default: next[alarm.id] = .scheduled
          }
        }
        if next != states { states = next }
      #endif
    }
  }
#endif

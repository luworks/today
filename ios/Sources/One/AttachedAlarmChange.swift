#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore
  import TodayData

  /// A preview for one existing alarm. Creating a proposal never changes the alarm.
  /// The caller owns the Apply button and must retain the returned ledger item for Undo.
  @MainActor
  package struct AttachedAlarmChange {
    package enum Edit {
      case rename(String)
      case move(Date)
      case delete
    }

    package enum Failure: LocalizedError {
      case unavailable, changed, unsupported, noChange

      package var errorDescription: String? {
        switch self {
        case .unavailable: "This alarm is no longer available."
        case .changed: "This alarm changed since the preview. Open it and try again."
        case .unsupported: "This alarm change isn't supported here. Open the alarm to edit it."
        case .noChange: "The alarm already has these settings."
        }
      }
    }

    private let id: PersistentIdentifier
    private let systemID: UUID
    private let before: AlarmSnapshot
    private let createdAt: Date
    private let edit: Edit

    package init(alarm: OneAlarm, edit: Edit) throws {
      guard !alarm.isDeleted, alarm.modelContext != nil, let systemID = alarm.alarmKitID else {
        throw Failure.unavailable
      }
      if case .rename(let name) = edit, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw Failure.unsupported
      }
      self.id = alarm.persistentModelID
      self.systemID = systemID
      self.before = alarm.activitySnapshot
      self.createdAt = alarm.createdAt
      self.edit = edit
    }

    /// Call only after explicit Apply. A one-off can only move to its next occurrence:
    /// AlarmKit's time-of-day schedule cannot represent an arbitrary future date.
    package func apply(
      context: ModelContext, alarms: any AlarmService, ledger: Ledger, runtime: PlannerRuntime,
      actor: LedgerActor = .todayAI, channel: LedgerChannel = .ask
    ) async throws -> LedgerItem {
      let matches = try context.fetch(FetchDescriptor<OneAlarm>()).filter {
        $0.persistentModelID == id
      }
      guard matches.count == 1, let alarm = matches.first, !alarm.isDeleted,
        alarm.alarmKitID == systemID
      else { throw Failure.unavailable }
      let reader = ModelContext(context.container)
      let saved = try reader.fetch(FetchDescriptor<OneAlarm>()).filter {
        $0.persistentModelID == id
      }
      guard saved.count == 1, let persisted = saved.first,
        persisted.alarmKitID == systemID, persisted.activitySnapshot == before,
        persisted.createdAt == createdAt, alarm.activitySnapshot == before,
        alarm.createdAt == createdAt
      else { throw Failure.changed }

      if case .delete = edit {
        _ = try AlarmActions.remove(alarm, context: context, alarms: alarms)
        return ledger.record(
          .deleted, kind: "alarm", title: alarmTitle(alarm, runtime: runtime),
          actor: actor, channel: channel, approval: actor == .you ? .userMade : .asked,
          snapshot: AlarmChange(before: before, after: nil), context: context)
      }
      var after = before
      let now = runtime.now()
      switch edit {
      case .delete: throw Failure.unsupported
      case .rename(let name):
        after.label = name.trimmingCharacters(in: .whitespacesAndNewlines)
      case .move(let date):
        guard before.weekdays.isEmpty, before.isOn, date > now else { throw Failure.unsupported }
        let calendar = runtime.calendar
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute,
          let next = calendar.nextDate(
            after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime),
          calendar.isDate(next, equalTo: date, toGranularity: .minute)
        else { throw Failure.unsupported }
        after.hour = hour
        after.minute = minute
      }
      guard after != before else { throw Failure.noChange }
      alarm.apply(after)
      if case .move = edit { alarm.createdAt = now }
      try await alarms.commit(alarm, context: context)
      let entry = ledger.record(
        .edited, item: alarm, kind: "alarm", title: alarmTitle(alarm, runtime: runtime),
        actor: actor, channel: channel, approval: actor == .you ? .userMade : .asked,
        snapshot: AlarmChange(before: before, after: alarm.activitySnapshot), context: context)
      return entry
    }

    /// Uses the same stale-state check, system scheduling and Activity receipt as Activity Undo.
    package static func undo(
      _ entry: LedgerItem, context: ModelContext, alarms: any AlarmService,
      ledger: Ledger, runtime: PlannerRuntime
    ) async -> String? {
      await AlarmActions.undo(
        entry, context: context, alarms: alarms, ledger: ledger, runtime: runtime)
    }
  }
#endif

#if os(iOS)
  import Foundation
  import SwiftUI
  import SwiftData
  import TodayCore
  import TodayData
  /// "Alarm 07:00" or "Alarm 07:00 · Gym", for Activity.
  @MainActor
  package func alarmTitle(_ a: OneAlarm, runtime: PlannerRuntime) -> String {
    let date =
      runtime.calendar.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: runtime.now())
      ?? runtime.now()
    let time = date.formatted(date: .omitted, time: .shortened)
    return a.label.isEmpty ? "Alarm \(time)" : "Alarm \(time) · \(a.label)"
  }

  /// Deleting an alarm from outside the Alarms tab (the Calendar's list): Activity records it, the system alarm is
  /// cancelled, and the toast offers Undo, like Delete on the Alarms tab.
  @MainActor
  package enum AlarmActions {
    package enum Failure: LocalizedError {
      case busy, unavailable, stale, compensation, localDelete
      package var errorDescription: String? {
        switch self {
        case .busy: "Alarm is updating. Please try again."
        case .unavailable:
          "Alarm access is unavailable. Check Today’s alarm permission and try again."
        case .stale: "This alarm is no longer available. Close the editor and try again."
        case .localDelete:
          "The system alarm was cancelled, but its saved row could not be deleted. The row is kept; open it and Save to restore ringing, or retry Delete."
        case .compensation:
          "The alarm could not be restored in the system. Your previous settings are kept. Check the alarm and retry Save."
        }
      }
    }

    /// The caller serializes this operation with reconciliation. Never hold edited
    /// model values across an await: autosave must not publish an unconfirmed draft.
    package static func persist(
      _ alarm: OneAlarm, context: ModelContext,
      schedule: @MainActor (OneAlarm) async throws -> Void,
      cancel: @MainActor (OneAlarm) throws -> Void,
      save: (@MainActor () throws -> Void)? = nil
    ) async throws {
      let isNew = alarm.modelContext == nil
      guard !alarm.isDeleted else { throw Failure.stale }
      let proposed = alarm.snapshot()
      var previous: OneAlarm?
      if !isNew {
        guard alarm.modelContext === context else { throw Failure.stale }
        let reader = ModelContext(context.container)
        let id = alarm.persistentModelID
        let saved = try reader.fetch(FetchDescriptor<OneAlarm>()).first {
          $0.persistentModelID == id
        }
        guard let saved else { throw Failure.stale }
        previous = saved.snapshot()
        alarm.restoreSettings(from: saved)
      }
      if alarm.alarmKitID == nil { alarm.alarmKitID = UUID() }
      proposed.alarmKitID = alarm.alarmKitID
      previous?.alarmKitID = alarm.alarmKitID
      let matches = try context.fetch(FetchDescriptor<OneAlarm>()).filter {
        $0.alarmKitID == alarm.alarmKitID && $0 !== alarm
      }
      guard matches.isEmpty else { throw Failure.stale }
      do {
        try await schedule(proposed)
        guard !alarm.isDeleted, isNew || alarm.modelContext === context else { throw Failure.stale }
        alarm.restoreSettings(from: proposed)
        alarm.alarmKitSignature = proposed.scheduleSignature
        if isNew { context.insert(alarm) }
        if let save { try save() } else { try context.save() }
      } catch {
        let originalError = error
        if let previous {
          alarm.restoreSettings(from: previous)
        } else if alarm.modelContext != nil {
          context.delete(alarm)
        }
        do {
          if let previous, previous.isOn {
            try await schedule(previous)
          } else {
            try cancel(proposed)
          }
        } catch {
          if previous != nil {
            // Missing system state is a failed restoration, not proof that a
            // one-time alarm rang. Reconciliation must retry this exact ID.
            alarm.alarmKitSignature = nil
            do { try context.save() } catch { throw Failure.compensation }
          }
          throw Failure.compensation
        }
        throw originalError
      }
    }

    @discardableResult
    package static func remove(
      _ alarm: OneAlarm, context: ModelContext, alarms: any AlarmService
    ) throws -> OneAlarm {
      guard !alarm.isDeleted, alarm.modelContext === context else { throw Failure.stale }
      let backup = alarm.snapshot()
      try alarms.cancel(alarm)
      context.delete(alarm)
      do { try context.save() } catch {
        context.insert(alarm)
        // Cancellation succeeded, but disk did not. Keep the original ID and let
        // reconciliation restore the retained row, never report a successful delete.
        alarm.alarmKitSignature = nil
        throw Failure.localDelete
      }
      return backup
    }

    @discardableResult
    package static func delete(
      _ alarm: OneAlarm, context: ModelContext, toast: UndoToast?, alarms: any AlarmService,
      ledger: Ledger, runtime: PlannerRuntime
    ) -> Bool {
      do {
        var backup = try remove(alarm, context: context, alarms: alarms)
        let entry = ledger.record(
          .deleted, kind: "alarm", title: alarmTitle(backup, runtime: runtime),
          snapshot: AlarmChange(before: backup.activitySnapshot, after: nil), context: context)
        var restoring = false
        func restore() {
          // Activity's Undo may have put it back already.
          guard !restoring, backup.modelContext == nil, !ledger.isUndone(entry) else { return }
          restoring = true
          Task { @MainActor in
            defer { restoring = false }
            do {
              try await alarms.commit(backup, context: context)
              ledger.recordUndo(of: entry, item: backup, context: context)
            } catch {
              backup = backup.snapshot()
              toast?.show(
                "Couldn’t restore alarm. Check alarm access and try Undo again.", undo: restore)
            }
          }
        }
        toast?.show("Deleted alarm", undo: restore)
        return true
      } catch {
        toast?.showNotice(error.localizedDescription)
        return false
      }
    }

    /// Records an edit made in the alarm editor, or a flip of its switch, with the settings before and after so Activity
    /// can put them back. Nothing is recorded when nothing changed.
    package static func recordChange(
      _ alarm: OneAlarm, from before: AlarmSnapshot, ledger: Ledger, runtime: PlannerRuntime,
      context: ModelContext, actor: LedgerActor = .you, channel: LedgerChannel = .app
    ) {
      let after = alarm.activitySnapshot
      guard after != before else { return }
      var onlySwitch = before
      onlySwitch.isOn = after.isOn
      let action: LedgerAction =
        onlySwitch == after ? (after.isOn ? .switchedOn : .switchedOff) : .edited
      ledger.record(
        action, item: alarm, kind: "alarm", title: alarmTitle(alarm, runtime: runtime),
        before: action == .edited ? summary(before, runtime: runtime) : "",
        after: action == .edited ? summary(after, runtime: runtime) : "",
        actor: actor, channel: channel,
        snapshot: AlarmChange(before: before, after: after), context: context)
    }

    /// Records a new alarm (Add Alarm, the chat, Siri) with its settings, so Activity's Undo can take it away again.
    @discardableResult
    package static func recordCreated(
      _ alarm: OneAlarm, title: String? = nil, after: String = "", ledger: Ledger,
      runtime: PlannerRuntime, context: ModelContext, actor: LedgerActor = .you,
      channel: LedgerChannel = .app, approval: LedgerApproval = .userMade
    ) -> LedgerItem {
      ledger.record(
        .created, item: alarm, kind: "alarm", title: title ?? alarmTitle(alarm, runtime: runtime),
        after: after, actor: actor, channel: channel, approval: approval,
        snapshot: AlarmChange(before: nil, after: alarm.activitySnapshot), context: context)
    }

    /// "07:00 · Every day · Gym", for an edit's before → after.
    private static func summary(_ s: AlarmSnapshot, runtime: PlannerRuntime) -> String {
      let parts = AlarmPlan.timeParts(hour: s.hour, minute: s.minute, locale: runtime.locale)
      let time = [parts.time, parts.suffix].compactMap { $0 }.joined(separator: " ")
      let repeats = AlarmPlan.repeatValue(weekdays: s.weekdays, calendar: runtime.calendar)
      return ([time, repeats] + (s.label.isEmpty ? [] : [s.label])).joined(separator: " · ")
    }

    private static var undoing: Set<UUID> = []

    /// Undo from Activity of an alarm change: takes an added alarm away, adds a deleted one back as a new alarm, or puts
    /// an edited one's settings back, and schedules it with AlarmKit. Returns nil when done, else why it could not.
    package static func undo(
      _ entry: LedgerItem, context: ModelContext, alarms: any AlarmService, ledger: Ledger,
      runtime: PlannerRuntime, fallback: AlarmChange? = nil
    ) async -> String? {
      guard entry.itemKind == "alarm", !undoing.contains(entry.id), !ledger.isUndone(entry),
        let change = ledger.undoSnapshot(AlarmChange.self, of: entry, context: context) ?? fallback
      else { return ActivityUndoMessage.changedSince }
      undoing.insert(entry.id)
      defer { undoing.remove(entry.id) }
      let alarm = ledger.model(OneAlarm.self, for: entry, in: context)
      let current = alarm.flatMap { $0.isDeleted ? nil : $0.activitySnapshot }
      guard let step = AlarmUndo.step(for: entry.actionValue, change: change, current: current)
      else { return ActivityUndoMessage.changedSince }
      switch step {
      case .remove:
        guard let alarm else { return ActivityUndoMessage.changedSince }
        do { try remove(alarm, context: context, alarms: alarms) } catch {
          return error.localizedDescription
        }
        ledger.recordUndo(of: entry, context: context)
      case .recreate(let settings):
        let restored = OneAlarm(hour: settings.hour, minute: settings.minute)
        restored.apply(settings)
        restored.createdAt = runtime.now()
        do { try await alarms.commit(restored, context: context) } catch {
          return error.localizedDescription
        }
        ledger.recordUndo(of: entry, item: restored, context: context)
      case .restore(let settings):
        guard let alarm else { return ActivityUndoMessage.changedSince }
        if alarm.isOn, alarms.state(of: alarm) != .scheduled {
          return ActivityUndoMessage.changedSince
        }
        let reader = ModelContext(context.container)
        let saved = try? reader.fetch(FetchDescriptor<OneAlarm>()).first {
          $0.persistentModelID == alarm.persistentModelID
        }
        guard let saved, saved.activitySnapshot == alarm.activitySnapshot,
          saved.createdAt == alarm.createdAt,
          change.afterCreatedAt == nil || change.afterCreatedAt == alarm.createdAt
        else { return ActivityUndoMessage.changedSince }
        if settings.weekdays.isEmpty, let originalCreatedAt = change.beforeCreatedAt {
          guard
            let original = AlarmPlan.nextFire(
              hour: settings.hour, minute: settings.minute,
              weekdays: [], after: originalCreatedAt, calendar: runtime.calendar),
            original > runtime.now()
          else { return "The original alarm time has passed. It cannot be restored exactly." }
        }
        alarm.apply(settings)
        alarm.createdAt = change.beforeCreatedAt ?? runtime.now()
        alarm.alarmKitSignature = nil
        do { try await alarms.commit(alarm, context: context) } catch {
          return error.localizedDescription
        }
        ledger.recordUndo(of: entry, item: alarm, context: context)
      }
      ledger.flush(context)
      return nil
    }
  }

  extension OneAlarm {
    /// The settings Activity keeps for Undo.
    package var activitySnapshot: AlarmSnapshot {
      AlarmSnapshot(
        hour: hour, minute: minute, label: label, note: note, weekdays: weekdays, isOn: isOn,
        snooze: snooze, sound: sound, snoozeMinutes: snoozeMinutes)
    }

    /// Puts kept settings back. Identity (`alarmKitID`) and `createdAt` stay as they are.
    package func apply(_ s: AlarmSnapshot) {
      hour = s.hour
      minute = s.minute
      label = s.label
      note = s.note
      weekdays = s.weekdays
      isOn = s.isOn
      snooze = s.snooze
      sound = s.sound
      snoozeMinutes = s.snoozeMinutes
    }
  }
#endif

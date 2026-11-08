#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore
  import TodayData

  extension Capture {
    package func makeTask(calendar: Calendar) -> OneTask {
      let timing = taskTiming(calendar: calendar)
      // A repeating reminder needs a date (Apple Reminders refuses one without): like Apple's app, today.
      let due = timing.due ?? (repeatRule == nil ? nil : calendar.startOfDay(for: .now))
      let t = OneTask(title: title, durationMinutes: durationMinutes ?? 25, due: due)
      t.note = notes ?? ""
      if let minutes = timing.alertMinutesBefore { t.reminderOffsetMinutes = minutes }
      t.repeatRule = repeatRule
      t.ringsAsAlarm = ringsAsAlarm && clockTime(calendar: calendar) != nil
      if let listName { t.listName = listName }
      return t
    }

    /// An alarm request becomes a real alarm (Alarms tab) when it can be one: it rings within the next day, or repeats
    /// daily / on selected weekdays / weekly. Anything else ("alarm next Friday at 7") stays a reminder that rings, on its own date.
    /// It starts like one made in Add Alarm or by Siri: `defaults` from Settings → Alarms.
    package func makeAlarm(
      now: Date, calendar cal: Calendar,
      defaults: AlarmPlan.NewAlarmDefaults = AlarmPlan.newAlarmDefaults()
    ) -> OneAlarm? {
      guard kind == .task, ringsAsAlarm, let start = clockTime(calendar: cal) else { return nil }
      let weekdays: [Int]
      switch repeatRule.flatMap(RepeatRule.init(rawValue:)) {
      case nil:
        guard start > now, start.timeIntervalSince(now) <= 86_400 else { return nil }
        weekdays = []
      case .daily: weekdays = Array(1...7)
      case .weekdays: weekdays = [2, 3, 4, 5, 6]
      case .weekly: weekdays = [cal.component(.weekday, from: start)]
      case .weeklyOn(let days): weekdays = Set(days).sorted()
      default: return nil
      }
      let c = cal.dateComponents([.hour, .minute], from: start)
      let alarm = OneAlarm.new(
        hour: c.hour ?? 0, minute: c.minute ?? 0, label: title, weekdays: weekdays,
        defaults: defaults, now: now)
      alarm.note = notes ?? ""
      return alarm
    }

    /// `alertMinutes`: the alert before the start (Settings → "New event alert"); nil = none.
    /// `defaultMinutes`: how long it lasts if the capture states no length (Settings → "New event length").
    package func makeEvent(
      calendar: Calendar, alertMinutes: Int? = Preferences.newEventAlert,
      defaultMinutes: Int = Preferences.newEventMinutes
    ) -> OneEvent {
      let start =
        clockTime(calendar: calendar) ?? calendar.date(
          bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
      let e = OneEvent(
        title: title, start: isAllDay ? day : start,
        durationMinutes: isAllDay ? 1440 : durationMinutes ?? defaultMinutes)
      e.note = notes ?? ""
      e.isAllDay = isAllDay
      e.repeatRule = repeatRule
      e.reminderOffsetMinutes = alertMinutes
      return e
    }

    /// Creates the right model for `kind` in `context`. Only called after the user taps Add.
    /// Inserts what this capture becomes and returns its id (final, after the save).
    /// Recorded in Activity as made by `actor` through `channel`.
    @MainActor @discardableResult
    package func insert(
      into context: ModelContext, actor: LedgerActor = .you, channel: LedgerChannel = .app,
      approval: LedgerApproval = .userMade, ledger: Ledger, runtime: PlannerRuntime,
      alarmDefaults: AlarmPlan.NewAlarmDefaults = AlarmPlan.newAlarmDefaults(),
      newEventMinutes: Int = Preferences.newEventMinutes()
    ) throws -> PersistentIdentifier {
      try insertRecorded(
        into: context, actor: actor, channel: channel, approval: approval, ledger: ledger,
        runtime: runtime, alarmDefaults: alarmDefaults, newEventMinutes: newEventMinutes
      ).id
    }

    /// `insert`, and the Activity entry that recorded it (so Undo can be recorded against it).
    @MainActor
    package func insertRecorded(
      into context: ModelContext, actor: LedgerActor = .you, channel: LedgerChannel = .app,
      approval: LedgerApproval = .userMade, ledger: Ledger, runtime: PlannerRuntime,
      alarmDefaults: AlarmPlan.NewAlarmDefaults = AlarmPlan.newAlarmDefaults(),
      newEventMinutes: Int = Preferences.newEventMinutes()
    ) throws -> (id: PersistentIdentifier, entry: LedgerItem) {
      let model: any PersistentModel
      switch kind {
      case .task:
        if let alarm = makeAlarm(
          now: runtime.now(), calendar: runtime.calendar, defaults: alarmDefaults)
        {
          model = alarm
        } else {
          model = makeTask(calendar: runtime.calendar)
        }
      case .event: model = makeEvent(calendar: runtime.calendar, defaultMinutes: newEventMinutes)
      }
      if let task = model as? OneTask { task.createdAt = runtime.now() }
      context.insert(model)
      do { try context.save() } catch {
        context.delete(model)
        throw error
      }  // A new model's id only becomes final on save; rows and sheets key on it.
      let kind = model is OneAlarm ? "alarm" : (model is OneEvent ? "event" : "task")
      let entry: LedgerItem
      if let alarm = model as? OneAlarm {
        entry = AlarmActions.recordCreated(
          alarm, title: title, after: summary, ledger: ledger, runtime: runtime, context: context,
          actor: actor, channel: channel, approval: approval)
      } else {
        entry = ledger.record(
          .created, task: model as? OneTask, kind: kind, title: title, after: summary,
          actor: actor, channel: channel, approval: approval, context: context)
      }
      return (model.persistentModelID, entry)
    }
  }

#endif

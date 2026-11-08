import Foundation
import TodayCore
import TodayData

#if os(iOS)
  import SwiftData
  import One
#endif

/// Developer launch compatibility, kept outside the production dependency graph.
/// Callers supply arguments and defaults explicitly; construction has no side effects.
public enum LaunchTestConfiguration {
  /// Preserve the existing UI launch contract without touching production stores or preferences.
  public static func applyActivityOverrides(
    arguments: [String], defaults: UserDefaults, store: ActivityStore, now: Date
  ) throws {
    guard arguments.contains("-uiTesting") else { return }
    if !arguments.contains("-uiTestingKeepActivitySettings") {
      for key in [
        ActivitySettings.pausedKey, ActivitySettings.retentionKey, ActivitySettings.keepChatTextKey,
      ] + ActivityTier.allCases.map(ActivitySettings.tierKey) {
        defaults.removeObject(forKey: key)
      }
      if arguments.contains("-uiTestingActivityPaused") {
        defaults.set(true, forKey: ActivitySettings.pausedKey)
      }
    }
    guard let i = arguments.firstIndex(of: "-uiTestingActivityRows"), i + 1 < arguments.count,
      let count = Int(arguments[i + 1]), count > 0
    else { return }
    let base = now.addingTimeInterval(-3600)
    let events = (0..<count).map { index -> ActivityEvent in
      var event = ActivityEvent(
        kind: "change.completed", tier: .changes, actor: "you", channel: "app",
        at: base.addingTimeInterval(-Double(index) * 60))
      event.title = "Synthetic \(index)"
      event.subjectKind = "task"
      event.approval = "user"
      return event
    }
    _ = try store.insert(events)
  }

  /// UI tests: `-appearance light|dark|system` sets the choice at launch; without it a `-uiTesting` run starts on System,
  /// unless `-uiTestingKeepAppearance` is passed (the relaunch check of the saved choice). Returns the value to store, if any.
  public static func appearanceOverride(arguments: [String]) -> Appearance? {
    guard arguments.contains("-uiTesting") else { return nil }
    if let i = arguments.firstIndex(of: "-appearance"), i + 1 < arguments.count,
      let a = Appearance(rawValue: arguments[i + 1])
    {
      return a
    }
    return arguments.contains("-uiTestingKeepAppearance") ? nil : .system
  }

  /// `-uiTesting` starts from the defaults (the in-memory store does not reset `UserDefaults`, so a switch flipped in one
  /// test would leak into the next), then `-uiTestingPrefs key=value,key=value` sets what a test needs
  /// (`dimPastDays=0`). Keys are the part after `today.setting.`. `-uiTestingKeepPreferences` skips the reset (the relaunch check).
  public static func applyPreferenceOverrides(arguments: [String], defaults: UserDefaults) {
    guard arguments.contains("-uiTesting") else { return }
    // Pill choices have a separate relaunch flag, matching the original UI-test launch contract.
    if !arguments.contains("-uiTestingKeepReminderPills") {
      for key in [SmartListLayout.orderKey, SmartListLayout.hiddenKey, "reminders.listsReordered"] {
        defaults.removeObject(forKey: key)
      }
    }
    guard !arguments.contains("-uiTestingKeepPreferences") else { return }
    for key in allKeys { defaults.removeObject(forKey: key) }
    guard let i = arguments.firstIndex(of: "-uiTestingPrefs"), i + 1 < arguments.count else {
      return
    }
    for pair in arguments[i + 1].split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      let key = "today.setting." + parts[0]
      guard allKeys.contains(key) else { continue }
      if let n = Int(parts[1]) {
        // 0 / 1 are switches, other numbers are hours or minutes; a switch key reads Bool, so store both ways.
        if switchKeys.contains(key) {
          defaults.set(n != 0, forKey: key)
        } else {
          defaults.set(n, forKey: key)
        }
      } else {
        defaults.set(parts[1], forKey: key)
      }
    }
  }

  private static let switchKeys: Set<String> = [
    Preferences.compressEmptyHoursKey, Preferences.dimPastDaysKey, Preferences.weekNumbersKey,
    Preferences.showSettleKey,
    Preferences.showFreeTimeKey, Preferences.weatherSummaryKey,
  ]

  private static let allKeys = [
    Preferences.compressEmptyHoursKey, Preferences.dimPastDaysKey, Preferences.firstWeekdayKey,
    Preferences.weekNumbersKey,
    Preferences.calendarStartKey,
    Preferences.showSettleKey,
    Preferences.showFreeTimeKey, Preferences.newReminderListKey,
    Preferences.newEventCalendarKey, Preferences.newEventAlertKey,
    Preferences.newAlarmSnoozeKey, Preferences.newAlarmSoundKey,
    Preferences.weatherSummaryKey, Preferences.upNextLiveActivityKey,
    CalendarLayout.savedHourHeightKey,
    Preferences.afternoonStartKey, Preferences.eveningStartKey, Preferences.freeRowMinutesKey,
    Preferences.newEventMinutesKey, Preferences.quickPresetsKey,
    Preferences.reminderInterruptionKey, Preferences.aiChangesKey,
  ]
}

#if os(iOS) && DEBUG
  @MainActor
  extension LaunchTestConfiguration {
    /// The AlarmKit id of the seeded "Morning alarm", so its recorded Stop matches its ring.
    package static let pastDayAlarmID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!

    /// UI tests only (`-uiTesting -uiTestingPastDay`): yesterday as Activity would have recorded it. Shown: "Feed the cat"
    /// (still in Today, done at 08:30; its ledger row must not show twice), "Return library books" (completed at 10:15, then
    /// deleted), "Morning alarm" stopped at 07:04, "Old alarm" stopped at 06:15 (since deleted), "Team lunch" (12:00, deleted at
    /// 15:00) and "Send the weekly report" (due 17:00, still open). Hidden: "Tapped by mistake" (reopened a minute later),
    /// "Undone in Activity" (undone) and "Cancelled call" (deleted before it began).
    package static func seedPastDayForTests(
      context: ModelContext, store: ActivityStore?, arguments: [String], runtime: PlannerRuntime
    ) {
      guard arguments.contains("-uiTesting"), arguments.contains("-uiTestingPastDay"),
        let store
      else { return }
      let cal = runtime.calendar
      let today = cal.startOfDay(for: runtime.now())
      guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return }
      func at(_ hour: Int, _ minute: Int, on day: Date = yesterday) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
      }
      let alarm = OneAlarm(hour: 7, minute: 0, label: "Morning alarm", weekdays: Array(1...7))
      alarm.alarmKitID = pastDayAlarmID
      context.insert(alarm)
      let fed = OneTask(title: "Feed the cat", due: at(8, 0))
      fed.isDone = true
      fed.doneAt = at(8, 30)
      context.insert(fed)
      context.insert(OneTask(title: "Send the weekly report", due: at(17, 0)))
      try? context.save()

      func event(
        _ kind: String, _ title: String, at date: Date, subject: String = "task", ref: String? = nil
      ) -> ActivityEvent {
        var e = ActivityEvent(
          kind: kind, tier: ActivityKind.tier(of: kind), actor: "you", channel: "app", at: date,
          calendar: cal)
        e.title = title
        e.subjectKind = subject
        e.subjectRef = ref
        return e
      }
      var events = [
        event(
          "change.completed", "Feed the cat", at: at(8, 30),
          ref: Ledger.ref(fed.persistentModelID)),
        event("change.completed", "Return library books", at: at(10, 15), ref: "gone-books"),
        event("change.deleted", "Return library books", at: at(9, 0, on: today)),
        event("change.completed", "Tapped by mistake", at: at(11, 0), ref: "mistake"),
        event("change.reopened", "Tapped by mistake", at: at(11, 1), ref: "mistake"),
        event(
          "sys.alarm.stopped", "Morning alarm", at: at(7, 4), subject: "alarm",
          ref: pastDayAlarmID.uuidString),
        event(
          "sys.alarm.stopped", "Old alarm", at: at(6, 15), subject: "alarm",
          ref: UUID().uuidString),
      ]
      let undone = event("change.completed", "Undone in Activity", at: at(11, 30), ref: "undone")
      var undo = event("change.undone", "Undone in Activity", at: at(11, 31), ref: "undone")
      undo.undoOf = undone.uid
      events += [undone, undo]
      for (title, start, deleted) in [
        ("Team lunch", at(12, 0), at(15, 0)), ("Cancelled call", at(16, 0), at(9, 0)),
      ] {
        var e = event("change.deleted", title, at: deleted, subject: "event")
        e.beforeTs = ActivityClock.ms(start)
        e.afterTs = ActivityClock.ms(start.addingTimeInterval(3600))
        events.append(e)
      }
      _ = try? store.insert(events)
    }
  }
#endif

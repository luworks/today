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
    Preferences.showFreeTimeKey, Preferences.askSuggestionsKey, Preferences.weatherSummaryKey,
  ]

  private static let allKeys = [
    Preferences.compressEmptyHoursKey, Preferences.dimPastDaysKey, Preferences.firstWeekdayKey,
    Preferences.weekNumbersKey,
    Preferences.calendarStartKey,
    Preferences.showSettleKey,
    Preferences.showFreeTimeKey, Preferences.newReminderListKey,
    Preferences.newAlarmSnoozeKey, Preferences.newAlarmSoundKey, Preferences.askSuggestionsKey,
    Preferences.weatherSummaryKey, Preferences.aiAgentKey,
  ]
}

#if os(iOS) && DEBUG
  @MainActor
  extension LaunchTestConfiguration {
    /// UI tests only (`-uiTesting -uiTestingLegacyLedgerRows <n>`): writes n old-style `LedgerEntry` rows, as an install from
    /// before the Activity store would have them, so the real import can be tested end to end. Only when there are none yet.
    package static func seedLegacyLedgerForTests(
      context: ModelContext, arguments: [String], runtime: PlannerRuntime
    ) {
      let args = arguments
      guard args.contains("-uiTesting"), let i = args.firstIndex(of: "-uiTestingLegacyLedgerRows"),
        i + 1 < args.count,
        let n = Int(args[i + 1]), n >= 5,
        ((try? context.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0) == 0
      else { return }
      func entry(
        _ minutesAgo: Int, _ actor: LedgerActor, _ action: LedgerAction, _ title: String,
        approval: LedgerApproval = .userMade
      ) -> LedgerEntry {
        LedgerEntry(
          date: runtime.now().addingTimeInterval(-Double(minutesAgo) * 60), actor: actor,
          channel: .app, action: action,
          itemKind: "task", title: title, before: "Not planned", after: "Today 10:00",
          approval: approval)
      }
      let plan = entry(1, .todayAI, .planned, "Legacy plan", approval: .asked)
      let deleted = entry(2, .you, .deleted, "Legacy deleted")
      deleted.snapshot = try? JSONEncoder().encode(TaskSnapshot(title: "Legacy deleted"))
      let done = entry(3, .you, .completed, "Legacy done")
      let undo = entry(4, .you, .undone, "Legacy done")
      undo.undoOf = done.id
      for e in [plan, deleted, done, undo] { context.insert(e) }
      for k in 4..<n { context.insert(entry(5 + k, .siri, .created, "Legacy filler \(k)")) }
      try? context.save()
    }
  }
#endif

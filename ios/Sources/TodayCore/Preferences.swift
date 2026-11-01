import Foundation

/// The choices in Settings that were added after the first release: their keys, their defaults, and plain readers.
/// Plain Swift (Foundation only) so the defaults run under `swift test`. Every default is what the app did before the
/// choice existed. Screens read these through `@AppStorage`
/// with the same key and default; the readers here are for code that is not a view.
///
/// The older choices (overdue, alarms, scroll to now, travel time, Health summary, chat archive) keep their keys in
/// `SettingsKey`; Appearance has its own in `Appearance`.
public enum Preferences {
  // MARK: Keys

  public static let compressEmptyHoursKey = "today.setting.compressEmptyHours"
  public static let dimPastDaysKey = "today.setting.dimPastDays"
  public static let firstWeekdayKey = "today.setting.firstWeekday"
  public static let weekNumbersKey = "today.setting.weekNumbers"
  public static let calendarStartKey = "today.setting.calendarStart"
  public static let showSettleKey = "today.setting.showSettle"
  public static let showFreeTimeKey = "today.setting.showFreeTime"
  public static let newReminderListKey = "today.setting.newReminderList"
  public static let newAlarmSnoozeKey = "today.setting.newAlarmSnooze"
  public static let newAlarmSoundKey = "today.setting.newAlarmSound"
  public static let askSuggestionsKey = "today.setting.askSuggestions"
  public static let weatherSummaryKey = "today.setting.weatherSummary"

  static let allKeys = [
    compressEmptyHoursKey, dimPastDaysKey, firstWeekdayKey, weekNumbersKey, calendarStartKey,
    showFreeTimeKey, newReminderListKey, newAlarmSnoozeKey, newAlarmSoundKey,
    askSuggestionsKey, showSettleKey, weatherSummaryKey,
  ]

  /// The on-phone AI agent (docs/engineering/ai-agent-architecture.md P2). Off by default: Ask keeps the
  /// existing pipeline. Not a `today.setting.` key: it is a development flag until P4 turns the agent on.
  public static let aiAgentKey = "today.ai.agent"
  public static let aiAgent = false
  /// Launch argument that turns the agent on for one run (testing).
  public static let aiAgentArgument = "-aiAgent"

  /// Whether Ask routes messages that FastLane doesn't take to the agent.
  public static func aiAgentEnabled(
    _ defaults: UserDefaults = .standard,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    arguments.contains(aiAgentArgument)
      || (defaults.object(forKey: aiAgentKey) as? Bool ?? aiAgent)
  }

  // MARK: Defaults (the behaviour before these choices existed)

  public static let compressEmptyHours = true
  public static let dimPastDays = true
  public static let firstWeekday = FirstWeekday.system
  public static let weekNumbers = false
  public static let calendarStart = CalendarStart.lastUsed
  public static let showSettle = true
  public static let showFreeTime = true
  /// "" = Auto: the list the text clearly belongs to, else the Inbox (Ask), else the default list (quick add).
  public static let newReminderList = ""
  public static let newAlarmSnooze = AlarmPlan.defaultSnoozeMinutes
  /// "" = the system alarm sound.
  public static let newAlarmSound = ""
  public static let askSuggestions = true
  public static let weatherSummary = false

  // MARK: Choices

  /// Which day the week starts on in Calendar (Month and Year, and the week numbers). System follows the region set on the iPhone.
  public enum FirstWeekday: String, CaseIterable, Identifiable, Sendable {
    case system, sunday, monday
    public var id: String { rawValue }

    public init(stored: String?) {
      self = stored.flatMap(FirstWeekday.init(rawValue:)) ?? Preferences.firstWeekday
    }

    public var title: String {
      switch self {
      case .system: "System"
      case .sunday: "Sunday"
      case .monday: "Monday"
      }
    }

    /// Calendar weekday numbers: 1 = Sunday, 2 = Monday. nil = leave the calendar as the system has it.
    public var weekday: Int? {
      switch self {
      case .system: nil
      case .sunday: 1
      case .monday: 2
      }
    }

    /// `base` with this week start applied (a copy; the system calendar is never changed).
    public func calendar(base: Calendar = .current) -> Calendar {
      guard let weekday else { return base }
      var c = base
      c.firstWeekday = weekday
      return c
    }
  }

  /// Which Calendar view opens when the app starts. Last used keeps the view you left it in.
  public enum CalendarStart: String, CaseIterable, Identifiable, Sendable {
    case lastUsed, twoDay, month, year
    public var id: String { rawValue }

    /// A retired choice (`week`, `threeDay`) or anything unknown is the default.
    public init(stored: String?) {
      self = stored.flatMap(CalendarStart.init(rawValue:)) ?? Preferences.calendarStart
    }

    public var title: String {
      switch self {
      case .lastUsed: "Last used"
      case .twoDay: "2 Day"
      case .month: "Month"
      case .year: "Year"
      }
    }

    /// The view to open (a `CalendarView.Mode` raw value): this choice when it names one, else the last used
    /// (2 Day the very first time). A retired last view ("Week", "ThreeDay") is not a mode, so it opens the default.
    public func view(lastUsed: String?) -> String {
      switch self {
      case .lastUsed: lastUsed ?? "TwoDay"
      case .twoDay: "TwoDay"
      case .month: "Month"
      case .year: "Year"
      }
    }
  }

  // MARK: Readers for code that is not a view

  public static func firstWeekdayChoice(_ defaults: UserDefaults = .standard) -> FirstWeekday {
    FirstWeekday(stored: defaults.string(forKey: firstWeekdayKey))
  }

  public static func calendarStartChoice(_ defaults: UserDefaults = .standard) -> CalendarStart {
    CalendarStart(stored: defaults.string(forKey: calendarStartKey))
  }

  /// The list a new reminder goes to when nothing else says (see `newReminderList`), only if it still exists.
  public static func newReminderList(existing names: [String], _ defaults: UserDefaults = .standard)
    -> String?
  {
    guard let name = defaults.string(forKey: newReminderListKey), !name.isEmpty,
      names.contains(name)
    else { return nil }
    return name
  }

  public static func newAlarmSnoozeMinutes(_ defaults: UserDefaults = .standard) -> Int {
    AlarmPlan.snoozeMinutes(
      nearest: defaults.object(forKey: newAlarmSnoozeKey) as? Int ?? newAlarmSnooze)
  }

  public static func newAlarmSoundName(_ defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: newAlarmSoundKey) ?? newAlarmSound
  }

  // MARK: One-time notices (not Settings)

  /// The Clock tab's "Alarms live in Today now" card: shown once, then never again (also after Delete All Data).
  public static let alarmIntroSeenKey = "today.notice.alarmIntroSeen"

  public static func alarmIntroSeen(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: alarmIntroSeenKey)
  }

  public static func markAlarmIntroSeen(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: alarmIntroSeenKey)
  }
}

extension Calendar {
  /// The calendar the Calendar tab lays weeks out with: the system calendar, with the first day of the week the user chose.
  /// Read on every call, so a change in Settings shows at once.
  public static var app: Calendar { Preferences.firstWeekdayChoice().calendar() }
}

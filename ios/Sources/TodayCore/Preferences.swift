import Foundation

/// The choices in Settings that were added after the first release: their keys, their defaults, and plain readers.
/// Plain Swift (Foundation only) so the defaults run under `swift test`. Every default is what the app did before the
/// choice existed, unless its own comment says otherwise. Screens read these through `@AppStorage`
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
  public static let newEventCalendarKey = "today.setting.newEventCalendar"
  public static let newEventAlertKey = "today.setting.newEventAlert"
  public static let newAlarmSnoozeKey = "today.setting.newAlarmSnooze"
  public static let newAlarmSoundKey = "today.setting.newAlarmSound"
  public static let weatherSummaryKey = "today.setting.weatherSummary"
  public static let upNextLiveActivityKey = "today.setting.upNextLiveActivity"
  public static let afternoonStartKey = "today.setting.afternoonStart"
  public static let eveningStartKey = "today.setting.eveningStart"
  public static let freeRowMinutesKey = "today.setting.freeRowMinutes"
  public static let newEventMinutesKey = "today.setting.newEventMinutes"

  static let allKeys = [
    compressEmptyHoursKey, dimPastDaysKey, firstWeekdayKey, weekNumbersKey, calendarStartKey,
    showFreeTimeKey, newReminderListKey, newEventCalendarKey, newEventAlertKey,
    newAlarmSnoozeKey, newAlarmSoundKey, showSettleKey, weatherSummaryKey,
    upNextLiveActivityKey, afternoonStartKey, eveningStartKey, freeRowMinutesKey,
    newEventMinutesKey,
  ]

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
  /// Calendar identifier for new events; "" = Auto (the calendar the request names, else the system default).
  public static let newEventCalendar = ""
  /// Minutes before a new event Today makes (Ask, the local editor); `noEventAlert` = none. Today always added 10.
  public static let newEventAlert = 10
  public static let noEventAlert = -1
  public static let newEventAlertChoices = [noEventAlert, 0, 5, 10, 30, 60]
  public static let weatherSummary = false
  /// ON by explicit owner decision (2026-11-08), overriding the rule that a new choice defaults to the old behaviour.
  /// The user can turn it off in Settings.
  public static let upNextLiveActivity = true
  public static let afternoonStart = DayPart.Boundaries.standard.afternoon
  public static let eveningStart = DayPart.Boundaries.standard.evening
  /// The shortest gap that gets a "Free" row on Today. The AI planner keeps its own minimum.
  public static let freeRowMinutes = 30
  public static let freeRowMinutesChoices = [15, 30, 60]
  /// How long a new event lasts when nothing states its end: not the user, the AI or a selected slot.
  public static let newEventMinutes = 60
  public static let newEventMinutesChoices = [15, 30, 45, 60, 90, 120]

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

  /// The calendar a new event goes to when nothing else says (see `newEventCalendar`), only if it still exists and
  /// can be written.
  public static func newEventCalendar(writable ids: [String], _ defaults: UserDefaults = .standard)
    -> String?
  {
    guard let id = defaults.string(forKey: newEventCalendarKey), !id.isEmpty, ids.contains(id)
    else { return nil }
    return id
  }

  /// Minutes before a new event's start for its alert, nil = no alert.
  public static func newEventAlertMinutes(_ defaults: UserDefaults = .standard) -> Int? {
    let stored = defaults.object(forKey: newEventAlertKey) as? Int ?? newEventAlert
    guard stored != noEventAlert else { return nil }
    return newEventAlertChoices.contains(stored) ? stored : newEventAlert
  }

  /// "None", "At time of event", "10 minutes before", "1 day before".
  public static func newEventAlertLabel(_ minutes: Int) -> String {
    minutes == noEventAlert ? "None" : EventAlert.label(TimeInterval(-minutes * 60))
  }

  public static func newAlarmSnoozeMinutes(_ defaults: UserDefaults = .standard) -> Int {
    AlarmPlan.snoozeMinutes(
      nearest: defaults.object(forKey: newAlarmSnoozeKey) as? Int ?? newAlarmSnooze)
  }

  public static func newAlarmSoundName(_ defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: newAlarmSoundKey) ?? newAlarmSound
  }

  public static func upNextLiveActivityEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: upNextLiveActivityKey) as? Bool ?? upNextLiveActivity
  }

  public static func dayBoundaries(_ defaults: UserDefaults = .standard) -> DayPart.Boundaries {
    DayPart.Boundaries(
      afternoon: defaults.object(forKey: afternoonStartKey) as? Int ?? afternoonStart,
      evening: defaults.object(forKey: eveningStartKey) as? Int ?? eveningStart)
  }

  /// A stored Free-row minimum, or the default if it is not one of the choices.
  public static func freeRowMinutes(stored: Int) -> Int {
    freeRowMinutesChoices.contains(stored) ? stored : freeRowMinutes
  }

  /// A stored new-event length, or the default if it is not one of the choices.
  public static func newEventMinutes(stored: Int) -> Int {
    newEventMinutesChoices.contains(stored) ? stored : newEventMinutes
  }

  public static func newEventMinutes(_ defaults: UserDefaults = .standard) -> Int {
    newEventMinutes(stored: defaults.object(forKey: newEventMinutesKey) as? Int ?? newEventMinutes)
  }

  /// "30 minutes", "1 hour", "1.5 hours".
  public static func newEventMinutesLabel(_ minutes: Int) -> String {
    switch minutes {
    case 60: "1 hour"
    case 90: "1.5 hours"
    case 120: "2 hours"
    default: "\(minutes) minutes"
    }
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

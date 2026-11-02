#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import SwiftData

  /// A real alarm (rings through Silent and Focus via AlarmKit). Not a reminder: reminders stay in
  /// Apple Reminders / Calendar; this is for "wake me up" things.
  ///
  /// Each alarm owns one AlarmKit alarm with a stable id (`alarmKitID`), so an edit or a delete touches
  /// exactly that alarm. AlarmKit only lists alarms this app scheduled, never the ones in Apple's Clock app.
  @Model
  package final class OneAlarm {
    package var hour: Int
    package var minute: Int
    package var label: String
    /// Context retained from AI capture; additive default for existing stores.
    package var note: String = ""
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty = rings once, at the next occurrence.
    package var weekdays: [Int] = []
    package var isOn: Bool = true
    /// When the alarm was last saved or switched on. A one-time alarm rings at the first occurrence after this.
    package var createdAt: Date
    /// Shows a Snooze button when the alarm rings (nine minutes, like Clock). Additive field: older stores get true.
    package var snooze: Bool = true
    /// The tone's name (see `AlarmSound`); empty = the system alarm sound. Additive field: older stores get the default.
    package var sound: String = ""
    /// Minutes between a snooze and the next ring (Clock's "Snooze Duration"). Older stores get nine.
    package var snoozeMinutes: Int = 9
    /// The id of this alarm's AlarmKit alarm. Set the first time it is scheduled; never changes after that.
    package var alarmKitID: UUID?
    /// What was last handed to AlarmKit for this id (see `scheduleSignature`), so a sync can tell whether
    /// the system alarm still matches and leave it alone, e.g. while it is ringing.
    package var alarmKitSignature: String?

    package init(
      hour: Int, minute: Int, label: String = "", weekdays: [Int] = [], snooze: Bool = true
    ) {
      self.hour = hour
      self.minute = minute
      self.label = label
      self.weekdays = weekdays
      self.snooze = snooze
      self.createdAt = .now
    }

    /// A new alarm as every path makes it (Add Alarm, the chat, Siri): the new-alarm sound and snooze from Settings.
    package static func new(
      hour: Int, minute: Int, label: String, weekdays: [Int],
      defaults: AlarmPlan.NewAlarmDefaults, now: Date
    ) -> OneAlarm {
      let alarm = OneAlarm(
        hour: hour, minute: minute, label: label, weekdays: weekdays, snooze: defaults.snooze)
      alarm.sound = defaults.sound
      alarm.snoozeMinutes = defaults.snoozeMinutes
      alarm.createdAt = now
      return alarm
    }

    /// An unsaved copy with the same settings, to put a deleted alarm back (Undo). It gets its own AlarmKit id.
    package func copy() -> OneAlarm {
      let a = OneAlarm(hour: hour, minute: minute, label: label, weekdays: weekdays, snooze: snooze)
      a.note = note
      a.isOn = isOn
      a.sound = sound
      a.snoozeMinutes = snoozeMinutes
      return a
    }

    /// Copies settings without changing either persistent or AlarmKit identity.
    package func restoreSettings(from source: OneAlarm) {
      hour = source.hour
      minute = source.minute
      label = source.label
      note = source.note
      weekdays = source.weekdays
      isOn = source.isOn
      createdAt = source.createdAt
      snooze = source.snooze
      sound = source.sound
      snoozeMinutes = source.snoozeMinutes
      alarmKitSignature = source.alarmKitSignature
    }

    package func snapshot() -> OneAlarm {
      let result = copy()
      result.createdAt = createdAt
      result.alarmKitID = alarmKitID
      result.alarmKitSignature = alarmKitSignature
      return result
    }

    /// The time of day as a date today (for pickers and display).
    package var timeToday: Date {
      Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    /// Clock's repeat value: "Never", "Every day", "Weekdays", "Every Mon, Wed", …
    package var repeatValue: String { AlarmPlan.repeatValue(weekdays: weekdays) }
    /// The line under the time in the list: "Alarm", "Alarm, Every day", …
    package var subtitle: String { AlarmPlan.rowSubtitle(label: label, weekdays: weekdays) }

    /// Everything that changes what AlarmKit has to ring, as a string (a `Hasher` seed changes per launch).
    /// `la2`: alarms carry `AlarmMeta` for the Live Activity and a Stop intent that records the stop; bumping the prefix makes
    /// the next sync reschedule older ones.
    package var scheduleSignature: String {
      "la2|\(isOn)|\(hour):\(minute)|\(weekdays.sorted())|\(label)|\(snooze)|\(sound)|\(snoozeMinutes)"
    }

    /// A one-time alarm turns itself off after it has rung, like Apple Clock.
    package func retireIfRung(now: Date = .now) {
      guard isOn, weekdays.isEmpty,
        let ring = AlarmPlan.nextFire(hour: hour, minute: minute, weekdays: [], after: createdAt),
        ring < now
      else { return }
      isOn = false
    }

    /// When this alarm will ring next, if it will.
    package func nextRing(now: Date = .now) -> Date? {
      guard isOn else { return nil }
      return AlarmPlan.nextRing(
        hour: hour, minute: minute, weekdays: weekdays, switchedOn: createdAt, now: now)
    }

    /// The plain values the Calendar and Today rules work on (see `CalendarAlarms`).
    package var spec: AlarmSpec {
      AlarmSpec(hour: hour, minute: minute, label: label, weekdays: weekdays, isOn: isOn)
    }

    /// When this alarm rings on `day`, if it does. A one-time alarm rings on the day of its next occurrence.
    package func fires(on day: Date, now: Date = .now, calendar: Calendar = .current) -> Date? {
      guard isOn else { return nil }
      return AlarmPlan.fire(
        on: day, hour: hour, minute: minute, weekdays: weekdays, now: now, calendar: calendar)
    }
  }
#endif

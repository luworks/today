#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData
  import One

  // MARK: - Today

  /// Settings > Today: the timeline's extras. Rows only; they sit inside the Today section.
  package struct TodayTimelineSettings: View {
    /// Records the Lock Screen Up Next switch and applies it.
    package init(upNextChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
      self.upNextChanged = upNextChanged
    }
    private let upNextChanged: @MainActor (Bool) -> Void
    @AppStorage(Preferences.upNextLiveActivityKey) private var upNext =
      Preferences.upNextLiveActivity
    @AppStorage(Preferences.showSettleKey) private var showsSettle = Preferences.showSettle
    @AppStorage(Preferences.showFreeTimeKey) private var showsFreeTime = Preferences.showFreeTime

    package var body: some View {
      ExplainedToggle(
        title: "Show Settle", isOn: $showsSettle,
        caption:
          "Show Settle actions and Settled items in Today. Settle hides an item in Today only. Turn this back on to access settled items."
      )
      ExplainedToggle(
        title: "Show free time", isOn: $showsFreeTime,
        caption: "Quiet “Free 1 h” lines in the gaps between your plans.")
      ExplainedToggle(
        title: "Up Next on Lock Screen", isOn: $upNext,
        caption: "A quiet card with what's coming in the next 3 hours. It never alerts you."
      )
      .onChange(of: upNext) { _, on in upNextChanged(on) }
    }
  }

  // MARK: - Calendar

  /// Settings > Calendar: how 2 Day, Month and Year look and where Calendar opens.
  package struct CalendarSettingsSection: View {
    /// Writable Apple calendars for "New events go to"; empty when Calendar access is off (the row is hidden).
    package init(calendars: [SystemCalendar] = []) {
      self.calendars = calendars.filter { $0.allowsContentModifications }
    }
    private let calendars: [SystemCalendar]
    @AppStorage(Preferences.newEventCalendarKey) private var newEventCalendar = Preferences
      .newEventCalendar
    @AppStorage(Preferences.newEventAlertKey) private var newEventAlert = Preferences.newEventAlert
    @AppStorage(Preferences.compressEmptyHoursKey) private var compressesEmptyHours =
      Preferences.compressEmptyHours
    @AppStorage(Preferences.dimPastDaysKey) private var dimsPast = Preferences.dimPastDays
    @AppStorage(Preferences.firstWeekdayKey) private var firstWeekday = Preferences.firstWeekday
      .rawValue
    @AppStorage(Preferences.weekNumbersKey) private var showsWeekNumbers = Preferences.weekNumbers
    @AppStorage(Preferences.calendarStartKey) private var calendarStart = Preferences.calendarStart
      .rawValue

    package var body: some View {
      Section {
        ExplainedToggle(
          title: "Compress empty hours", isOn: $compressesEmptyHours,
          caption: "Use less space for empty hours in 2 Day.")
        ExplainedToggle(
          title: "Dim past days", isOn: $dimsPast,
          caption:
            "Days that are over show in light grey in 2 Day and Month, and so do their events.")
        PillChoiceRow(
          title: "First day of the week",
          items: Preferences.FirstWeekday.allCases,
          selection: Binding(
            get: { Preferences.FirstWeekday(stored: firstWeekday) },
            set: { firstWeekday = $0.rawValue }),
          caption: "System follows the region set on your iPhone.",
          label: { $0.title }, identifier: { "settings.firstWeekday.\($0.rawValue)" })
        ExplainedToggle(
          title: "Show week numbers", isOn: $showsWeekNumbers,
          caption: "Beside each row in Month, and over the hours in 2 Day (the first day's week).")
        PillChoiceRow(
          title: "Open Calendar on",
          items: Preferences.CalendarStart.allCases,
          selection: Binding(
            get: { Preferences.CalendarStart(stored: calendarStart) },
            set: { calendarStart = $0.rawValue }),
          caption: "Applies when the app starts. Last used reopens the view you left.",
          label: { $0.title }, identifier: { "settings.calendarStart.\($0.rawValue)" })
        if !calendars.isEmpty {
          MenuChoiceRow(
            title: "New events go to", selection: $newEventCalendar,
            caption:
              "Auto uses the calendar an Ask request names (“family dinner” goes to Family), else your default calendar. Events you already have stay where they are.",
            identifier: "settings.newEventCalendar"
          ) {
            Text("Auto").tag("")
            ForEach(calendars) { c in
              Text(c.sourceTitle.isEmpty ? c.title : "\(c.title) (\(c.sourceTitle))").tag(c.id)
            }
          }
        }
        MenuChoiceRow(
          title: "New event alert",
          selection: Binding(
            get: {
              Preferences.newEventAlertChoices.contains(newEventAlert)
                ? newEventAlert : Preferences.newEventAlert
            }, set: { newEventAlert = $0 }),
          caption: "The alert an event added by Ask starts with. Each event can still be changed.",
          identifier: "settings.newEventAlert"
        ) {
          ForEach(Preferences.newEventAlertChoices, id: \.self) {
            Text(Preferences.newEventAlertLabel($0)).tag($0)
          }
        }
      } header: {
        Text("Calendar")
      }
    }
  }

  // MARK: - Reminders

  /// Settings > Reminders: where a new reminder goes when nothing else decides.
  package struct RemindersSettingsSection: View {
    package init() {}
    @AppStorage(Preferences.newReminderListKey) private var chosen = Preferences.newReminderList
    @Query(sort: \OneList.order) private var lists: [OneList]

    package var body: some View {
      Section {
        MenuChoiceRow(
          title: "New reminders go to", selection: $chosen,
          caption:
            "Auto files an Ask reminder in the list it clearly belongs to, else your Inbox, and a quick add in Reminders. A list you choose is used when nothing else decides. Reminders you already have stay where they are.",
          identifier: "settings.newReminderList"
        ) {
          Text("Auto").tag("")
          ForEach(lists.filter { !$0.name.isEmpty && $0.name != "Reminders" }) {
            Text($0.name).tag($0.name)
          }
        }
      } header: {
        Text("Reminders")
      }
    }
  }

  // MARK: - Alarms

  /// Settings > Alarms: what a new alarm starts with. Alarms you already have keep their own.
  package struct AlarmsSettingsSection: View {
    package init() {}
    @AppStorage(Preferences.newAlarmSnoozeKey) private var snooze = Preferences.newAlarmSnooze
    @AppStorage(Preferences.newAlarmSoundKey) private var sound = Preferences.newAlarmSound

    package var body: some View {
      Section {
        MenuChoiceRow(
          title: "Snooze length",
          selection: Binding(
            get: { AlarmPlan.snoozeMinutes(nearest: snooze) }, set: { snooze = $0 }),
          caption: nil, identifier: "settings.newAlarmSnooze"
        ) {
          ForEach(AlarmPlan.snoozeChoices, id: \.self) { Text("\($0) min").tag($0) }
        }
        MenuChoiceRow(
          title: "Sound", selection: $sound, caption: nil, identifier: "settings.newAlarmSound"
        ) {
          Text("Default").tag("")
          ForEach(AlarmSound.all) { Text($0.name).tag($0.name) }
        }
      } header: {
        Text("Alarms")
      } footer: {
        Text(
          "What a new alarm starts with. Each alarm can still be changed in its editor, and alarms you already have keep theirs."
        )
      }
    }
  }

// MARK: - AI

#endif

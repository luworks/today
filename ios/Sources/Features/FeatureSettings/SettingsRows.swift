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
    /// `upNextChanged` and `upNextOptionChanged` record a Lock Screen Up Next choice and apply it.
    package init(
      upNextChanged: @escaping @MainActor (Bool) -> Void = { _ in },
      upNextOptionChanged: @escaping @MainActor (String, String) -> Void = { _, _ in },
      settingChanged: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
      self.upNextChanged = upNextChanged
      self.upNextOptionChanged = upNextOptionChanged
      self.settingChanged = settingChanged
    }
    private let upNextChanged: @MainActor (Bool) -> Void
    private let upNextOptionChanged: @MainActor (String, String) -> Void
    private let settingChanged: @MainActor (String, String) -> Void
    @AppStorage(Preferences.upNextLiveActivityKey) private var upNext =
      Preferences.upNextLiveActivity
    @AppStorage(Preferences.showSettleKey) private var showsSettle = Preferences.showSettle
    @AppStorage(Preferences.showFreeTimeKey) private var showsFreeTime = Preferences.showFreeTime

    package var body: some View {
      ExplainedToggle(
        title: "Show Settle", isOn: $showsSettle,
        caption:
          "Show Settle actions and Settled items in Today. Settle hides an item in Today and on the Lock Screen and widgets. Turn this back on to access settled items."
      )
      ExplainedToggle(
        title: "Show free time", isOn: $showsFreeTime,
        caption: "Quiet “Free 1 h” lines in the gaps between your plans.")
      NavigationLink {
        DayDivisionSettings(settingChanged: settingChanged)
      } label: {
        Text("Divide the Day")
      }
      .accessibilityIdentifier("settings.divideTheDay")
      ExplainedToggle(
        title: "Up Next on Lock Screen", isOn: $upNext,
        caption: "A quiet card with what's coming up soon. It never alerts you."
      )
      .onChange(of: upNext) { _, on in upNextChanged(on) }
      if upNext {
        NavigationLink("Customize Up Next") { UpNextSettingsView(changed: upNextOptionChanged) }
      }
    }
  }

  /// Settings > Today > Divide the Day: where Morning, Afternoon and Evening meet, and how short a Free row can be.
  struct DayDivisionSettings: View {
    let settingChanged: @MainActor (String, String) -> Void
    @AppStorage(Preferences.afternoonStartKey) private var afternoon = Preferences.afternoonStart
    @AppStorage(Preferences.eveningStartKey) private var evening = Preferences.eveningStart
    @AppStorage(Preferences.freeRowMinutesKey) private var freeMinutes = Preferences.freeRowMinutes

    private var boundaries: DayPart.Boundaries {
      DayPart.Boundaries(afternoon: afternoon, evening: evening)
    }

    /// Stores the whole pair, so an unusable stored value cannot swallow the choice.
    private func store(_ new: DayPart.Boundaries) {
      afternoon = new.afternoon
      evening = new.evening
    }

    var body: some View {
      Form {
        Section {
          MenuChoiceRow(
            title: "Afternoon starts",
            selection: Binding(
              get: { boundaries.afternoon },
              set: {
                store(DayPart.Boundaries(afternoon: $0, evening: boundaries.evening))
              }),
            caption: nil, identifier: "settings.afternoonStart"
          ) {
            ForEach(boundaries.afternoonChoices, id: \.self) { Text(hourLabel($0)).tag($0) }
          }
          MenuChoiceRow(
            title: "Evening starts",
            selection: Binding(
              get: { boundaries.evening },
              set: {
                store(DayPart.Boundaries(afternoon: boundaries.afternoon, evening: $0))
              }),
            caption: nil, identifier: "settings.eveningStart"
          ) {
            ForEach(boundaries.eveningChoices, id: \.self) { Text(hourLabel($0)).tag($0) }
          }
        } footer: {
          Text("Morning runs until afternoon starts. An item stays in the part it starts in.")
        }
        Section {
          MenuChoiceRow(
            title: "Shortest free time",
            selection: Binding(
              get: { Preferences.freeRowMinutes(stored: freeMinutes) },
              set: { freeMinutes = $0 }),
            caption: nil, identifier: "settings.freeRowMinutes"
          ) {
            ForEach(Preferences.freeRowMinutesChoices, id: \.self) { Text("\($0) min").tag($0) }
          }
        } footer: {
          Text("Gaps shorter than this get no Free row on Today.")
        }
      }
      .navigationTitle("Divide the Day")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: afternoon) { _, value in
        settingChanged(Preferences.afternoonStartKey, String(value))
      }
      .onChange(of: evening) { _, value in
        settingChanged(Preferences.eveningStartKey, String(value))
      }
      .onChange(of: freeMinutes) { _, value in
        settingChanged(Preferences.freeRowMinutesKey, String(value))
      }
    }

    /// "12:00 PM" or "12:00", as the iPhone shows times.
    private func hourLabel(_ hour: Int) -> String {
      Calendar.current
        .date(
          bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))?
        .formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
  }

  // MARK: - Calendar

  /// Settings > Calendar: how 2 Day, Month and Year look and where Calendar opens.
  package struct CalendarSettingsSection: View {
    /// Writable Apple calendars for "New events go to"; empty when Calendar access is off (the row is hidden).
    package init(
      calendars: [SystemCalendar] = [],
      settingChanged: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
      self.calendars = calendars.filter { $0.allowsContentModifications }
      self.settingChanged = settingChanged
    }
    private let calendars: [SystemCalendar]
    private let settingChanged: @MainActor (String, String) -> Void
    @AppStorage(Preferences.newEventMinutesKey) private var newEventMinutes =
      Preferences.newEventMinutes
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
        MenuChoiceRow(
          title: "New event length",
          selection: Binding(
            get: { Preferences.newEventMinutes(stored: newEventMinutes) },
            set: { newEventMinutes = $0 }),
          caption: nil, identifier: "settings.newEventMinutes"
        ) {
          ForEach(Preferences.newEventMinutesChoices, id: \.self) {
            Text(Preferences.newEventMinutesLabel($0)).tag($0)
          }
        }
        .onChange(of: newEventMinutes) { _, value in
          settingChanged(Preferences.newEventMinutesKey, String(value))
        }
      } header: {
        Text("Calendar")
      }
    }
  }

  // MARK: - Reminders

  /// Settings > Reminders: where a new reminder goes when nothing else decides.
  package struct RemindersSettingsSection: View {
    package init(
      settingChanged: @escaping @MainActor (String, String) -> Void = { _, _ in },
      interruptionChanged: @escaping @MainActor (String) -> Void = { _ in }
    ) {
      self.settingChanged = settingChanged
      self.interruptionChanged = interruptionChanged
    }
    private let settingChanged: @MainActor (String, String) -> Void
    private let interruptionChanged: @MainActor (String) -> Void
    @AppStorage(Preferences.newReminderListKey) private var chosen = Preferences.newReminderList
    @AppStorage(Preferences.reminderInterruptionKey) private var interruption =
      Preferences.reminderInterruption
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
        NavigationLink {
          QuickPresetSettings(settingChanged: settingChanged)
        } label: {
          Text("Quick-Add Times")
        }
        .accessibilityIdentifier("settings.quickPresets")
        NavigationLink {
          ReminderInterruptionSettings(changed: interruptionChanged)
        } label: {
          LabeledContent(
            "Notifications", value: Preferences.reminderInterruption(stored: interruption).title)
        }
        .accessibilityIdentifier("settings.reminderInterruption")
      } header: {
        Text("Reminders")
      }
    }
  }

  /// Settings > AI > AI Changes: whether a clear request is written right away or waits on its card.
  struct AIChangesSettings: View {
    let settingChanged: @MainActor (String, String) -> Void
    @AppStorage(Preferences.aiChangesKey) private var stored = Preferences.aiChanges

    private var choice: Binding<Preferences.AIChanges> {
      Binding(
        get: { Preferences.aiChanges(stored: stored) },
        set: { stored = $0.rawValue })
    }

    var body: some View {
      Form {
        Section {
          Picker("AI Changes", selection: choice) {
            ForEach(Preferences.AIChanges.allCases, id: \.self) {
              Text($0.title).tag($0)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("settings.aiChanges.picker")
        } footer: {
          Text(
            "Apply Directly makes a change you clearly ask for right away, with Undo. Preview First shows it on a card and writes nothing until you tap Add or Apply. Changes that reach other people or a whole series always wait for your tap."
          )
        }
      }
      .navigationTitle("AI Changes")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: stored) { _, value in settingChanged(Preferences.aiChangesKey, value) }
    }
  }

  /// Settings > Reminders > Notifications: how much a reminder's notification interrupts.
  struct ReminderInterruptionSettings: View {
    let changed: @MainActor (String) -> Void
    @AppStorage(Preferences.reminderInterruptionKey) private var stored =
      Preferences.reminderInterruption

    private var choice: Binding<Preferences.ReminderInterruption> {
      Binding(
        get: { Preferences.reminderInterruption(stored: stored) },
        set: { stored = $0.rawValue })
    }

    var body: some View {
      Form {
        Section {
          Picker("Notifications", selection: choice) {
            ForEach(Preferences.ReminderInterruption.allCases, id: \.self) {
              Text($0.title).tag($0)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("settings.reminderInterruption.picker")
        } footer: {
          Text(
            "Alarms and Ring as Alarm always ring. Reminders synced with Apple Reminders are alerted by Apple's app, so this doesn't change them."
          )
        }
      }
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: stored) { _, value in changed(value) }
    }
  }

  /// Settings > Reminders > Quick-Add Times: the four times on the quick-add grid's first row. Rows keep
  /// their place while you edit, so one doesn't jump under your finger; the grid always shows them in time order.
  struct QuickPresetSettings: View {
    let settingChanged: @MainActor (String, String) -> Void
    @AppStorage(Preferences.quickPresetsKey) private var stored = Preferences.quickPresets
    @State private var minutes: [Int] = []

    private static let reference = Date(timeIntervalSinceReferenceDate: 0)

    private func time(at index: Int) -> Binding<Date> {
      Binding(
        get: {
          let minute = minutes[index]
          return Calendar.current.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Self.reference)
            ?? Self.reference
        },
        set: { date in
          let c = Calendar.current.dateComponents([.hour, .minute], from: date)
          minutes[index] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
          stored = QuickTime.storedPresets(minutes)
        })
    }

    var body: some View {
      Form {
        Section {
          ForEach(minutes.indices, id: \.self) { index in
            DatePicker(
              "Time \(index + 1)", selection: time(at: index), displayedComponents: .hourAndMinute
            )
            .accessibilityIdentifier("settings.quickPreset.\(index)")
          }
        } footer: {
          Text("The four times at the top of quick add, shown earliest first.")
        }
        Section {
          Button("Reset to Defaults") {
            stored = Preferences.quickPresets
            minutes = QuickTime.presetMinutes(stored: stored)
          }
          .accessibilityIdentifier("settings.quickPresets.reset")
        }
      }
      .navigationTitle("Quick-Add Times")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear { minutes = QuickTime.presetMinutes(stored: stored).sorted() }
      .onChange(of: stored) { _, value in
        settingChanged(Preferences.quickPresetsKey, value.isEmpty ? "default" : value)
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

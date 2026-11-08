#if os(iOS)
  import One
  import TodayPlannerUI
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Adding a reminder in one screen, modeled on Due: type what, then set when with one tap on the grid
  /// (times of day, +/− nudges, days). No date picker unless you want one; Save is always one tap away.
  /// Editing an existing reminder still opens `TaskEditor` (notes, checklist, tags…).
  package struct QuickReminderSheet: View {
    private let actions: PlannerActions
    private let ledger: Ledger
    private let alarms: any AlarmService
    private let activity: ActivityCenter
    private let usesPreferredList: Bool
    @State private var saveError: String?
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \OneList.order) private var lists: [OneList]
    @Query private var tasks: [OneTask]

    @State private var title = ""
    /// When it reminds you (the reminder's due date and time). nil = no date.
    @State private var when: Date?
    @State private var listName: String
    @State private var flagged = false
    @State private var repeatRule: RepeatRule?
    @State private var ringsAsAlarm = false
    @State private var showsPicker = false
    /// When the sheet opened: how long a quick add takes (Activity data, usage).
    @State private var openedAt: Date
    /// What you are likely adding, from your own past reminders (`ReminderSuggest`). Worked out once when the sheet opens.
    @State private var suggestions: [ReminderSuggest.Suggestion] = []
    @FocusState private var focused: Bool

    package init(
      listName: String = "", usesPreferredList: Bool = true, actions: PlannerActions,
      ledger: Ledger, alarms: any AlarmService,
      activity: ActivityCenter, presentation: PlannerPresentation
    ) {
      self.actions = actions
      self.ledger = ledger
      self.alarms = alarms
      self.activity = activity
      self.usesPreferredList = usesPreferredList
      _when = State(
        initialValue: QuickTime.start(now: presentation.now, calendar: presentation.calendar))
      _openedAt = State(initialValue: presentation.now)
      _listName = State(initialValue: listName)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    package var body: some View {
      VStack(spacing: 0) {
        header
          .padding(.horizontal, 16)
        // Scrolls so a short phone (SE, mini) or a large text size still reaches the grid above the keyboard.
        ScrollView {
          VStack {
            Spacer(minLength: 60)
            card
            Spacer(minLength: 60)
          }
          .frame(minHeight: 440)
          .padding(.horizontal, 10)
          .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
      }
      .padding(.top, 16)
      .background(Color(.systemGroupedBackground))
      .performanceDestination("reminder.quick")
      .onAppear {
        focused = true
        // Settings > Reminders > "New reminders go to" (Auto leaves the list as it was opened).
        if usesPreferredList, listName.isEmpty,
          let chosen = Preferences.newReminderList(
            existing: lists.map(\.name), presentation.defaults)
        {
          listName = chosen
        }
        suggestions = ReminderSuggest.suggest(
          from: tasks.map {
            .init(
              title: $0.title, createdAt: $0.createdAt, due: $0.due,
              isOpen: !$0.isDone)
          }, now: presentation.now, calendar: presentation.calendar)
      }
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
      .alert(
        "Couldn’t Save Reminder",
        isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(saveError ?? "")
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.hidden)
    }

    // MARK: Header: cancel, options, save

    private var header: some View {
      HStack(spacing: 6) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle())
        }
        .tint(.primary)
        .accessibilityLabel("Cancel")

        Spacer(minLength: 0)

        Menu {
          Text("Auto snooze is not available for Apple Reminders")
          Button("Auto snooze off") {}.disabled(true)
        } label: {
          HStack(spacing: 0) {
            Image(systemName: "zzz")
            Text("–").font(.body)
          }.frame(width: 44, height: 44)
        }
        .accessibilityLabel("Auto snooze unavailable")

        Menu {
          Picker("Repeat", selection: $repeatRule) {
            Text("Repeat Off").tag(RepeatRule?.none)
            ForEach(RepeatRule.allCases, id: \.self) { rule in
              Text(
                QuickTime.repeatLabel(
                  rule, date: when ?? presentation.now,
                  calendar: presentation.calendar)
              )
              .tag(RepeatRule?.some(rule))
            }
          }
        } label: {
          Image(systemName: "repeat").frame(width: 40, height: 44)
            .foregroundStyle(repeatRule == nil ? Color.secondary : Color.primary)
        }
        .disabled(when == nil)
        .accessibilityLabel(repeatRule.map { "Repeat, \($0.label)" } ?? "Repeat")
        .accessibilityIdentifier("quick.repeat")

        Menu {
          Text("Apple Reminders uses its own alert sound")
          Picker("List", selection: $listName) {
            Text("Reminders").tag("")
            ForEach(lists.filter { !$0.name.isEmpty && $0.name != "Reminders" }) {
              Text($0.name).tag($0.name)
            }
          }
          Toggle("Flag", isOn: $flagged)
          if alarms.isAvailable {
            Toggle("Ring as alarm", isOn: $ringsAsAlarm)
          }
        } label: {
          Image(systemName: ringsAsAlarm ? "alarm.fill" : "bell")
            .frame(width: 40, height: 44)
        }
        .accessibilityLabel("Alert options")
        .accessibilityIdentifier("quick.alert")

        Spacer(minLength: 0)

        // The sheet's tint is .primary (white in Dark): the fill follows it, so the label takes the inverse.
        Button("Save", action: save)
          .font(.body.weight(.semibold))
          .foregroundStyle(Color(.systemBackground))
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .disabled(!canSave)
          .accessibilityIdentifier("quick.save")
      }
      .tint(.primary)
      .font(.title3)
      // Fixed-size icon buttons, like the app's top and bottom bars: capped so they never clip.
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: The card: what, when, and the grid

    private var card: some View {
      VStack(spacing: 0) {
        TextField("Remind me to…", text: $title, axis: .vertical)
          .font(.title3)
          .lineLimit(1...4)
          .focused($focused)
          .submitLabel(.done)
          .padding(16)
          .accessibilityIdentifier("quick.title")

        whenBar
        if showsPicker, let when {
          DatePicker(
            "Date", selection: Binding(get: { when }, set: { self.when = $0 }),
            displayedComponents: [.date, .hourAndMinute]
          )
          .datePickerStyle(.graphical)
          .padding(.horizontal, 12)
        }
        grid
      }
      .background(
        Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Tap a guess to fill in the title and its usual time; Save is then one more tap.
    private var suggestionRow: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(suggestions, id: \.title) { s in
            Button {
              title = s.title
              if let w = s.when { set(w) }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(Color.accentColor)
                Text(s.title).lineLimit(1)
                if let w = s.when {
                  Text(
                    w.plannerFormatted(
                      date: .omitted, time: .shortened, runtime: presentation.runtime)
                  ).foregroundStyle(.secondary)
                }
              }
              .font(.subheadline)
              .padding(.horizontal, 12).padding(.vertical, 8)
              .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(PressScale())
            .tint(.primary)
            .accessibilityLabel("Suggestion, \(s.title)")
            .accessibilityIdentifier("quick.suggestion")
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
    }

    private var whenBar: some View {
      Button {
        if when == nil {
          when = QuickTime.start(now: presentation.now, calendar: presentation.calendar)
        }
        withAnimation(.snappy) { showsPicker.toggle() }
      } label: {
        HStack(spacing: 8) {
          if let when {
            Text(
              when.plannerFormatted(
                .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute(),
                runtime: presentation.runtime)
            )
            .font(.title3.weight(.medium))
            Text(QuickTime.relative(when, now: presentation.now)).font(.subheadline).opacity(0.8)
          } else {
            Text("No date").font(.title3.weight(.medium))
          }
          Spacer(minLength: 0)
        }
        .foregroundStyle(
          when == nil ? Color(.label) : Color.white
        )
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(
          when == nil
            ? Color(.tertiarySystemFill)
            : (colorScheme == .dark
              ? Color(red: 0.58, green: 0.16, blue: 0.16)
              : Color(red: 0.53, green: 0.09, blue: 0.09)))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("quick.when")
    }

    private var dayRow: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(QuickTime.Day.allCases) { day in
            chip(day.rawValue) {
              set(
                QuickTime.move(
                  when ?? QuickTime.start(now: presentation.now, calendar: presentation.calendar),
                  to: day, now: presentation.now, calendar: presentation.calendar))
            }
          }
          chip("No Date") {
            withAnimation(.snappy) {
              when = nil
              repeatRule = nil
              ringsAsAlarm = false
              showsPicker = false
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
    }

    private func chip(_ text: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(text).font(.subheadline.weight(.medium))
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(Color(.tertiarySystemFill), in: Capsule())
      }
      .buttonStyle(PressScale())
      .tint(.primary)
    }

    private var grid: some View {
      QuickTimeGrid(
        date: when, now: presentation.now, calendar: presentation.calendar,
        selectedDayPresets: true, set: set)
    }

    private func set(_ date: Date) {
      withAnimation(.snappy) { when = date }
    }

    // MARK: Save

    private func save() {
      let t = OneTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), due: when)
      t.listName = listName
      t.flagged = flagged
      t.reminderOffsetMinutes = when == nil ? nil : 0  // remind at the time you picked
      t.repeatRule = when == nil ? nil : repeatRule?.rawValue
      t.ringsAsAlarm = ringsAsAlarm && when != nil
      t.createdAt = presentation.now
      context.insert(t)
      do { try context.save() } catch {
        context.delete(t)
        saveError = "Your reminder was not saved. Please try again."
        return
      }
      ledger.record(
        .created, task: t, title: t.title, after: ledger.timeLabel(t.due, none: ""),
        context: context)
      activity.record(
        ActivityEvents.quickAddCommit(ms: Int(presentation.now.timeIntervalSince(openedAt) * 1000)))
      dismiss()
    }
  }

  /// Shared by quick add and reminder editing, including reminders opened from Calendar.
  /// Each cell keeps a 44-point target even when the surrounding sheet is compact.
  struct QuickTimeGrid: View {
    let date: Date?
    let now: Date
    let calendar: Calendar
    var selectedDayPresets = false
    let set: (Date) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(Preferences.quickPresetsKey) private var quickPresets = Preferences.quickPresets

    var body: some View {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 0),
          count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 0
      ) {
        ForEach(Array(QuickTime.presets(stored: quickPresets).enumerated()), id: \.offset) {
          _, preset in
          cell(String(format: "%02d:%02d", preset.hour, preset.minute)) {
            set(
              selectedDayPresets
                ? QuickTime.presetOnSelectedDay(
                  hour: preset.hour, minute: preset.minute, on: date ?? now, calendar: calendar)
                : QuickTime.preset(
                  hour: preset.hour, minute: preset.minute, on: date ?? now, now: now,
                  calendar: calendar))
          }
        }
        ForEach(QuickTime.nudges + QuickTime.nudges.map { -$0 }, id: \.self) { minutes in
          nudge(minutes)
        }
      }
      .sensoryFeedback(.selection, trigger: date)
    }

    private func nudge(_ minutes: Int) -> some View {
      cell(QuickTime.nudgeLabel(minutes)) {
        set(
          QuickTime.nudge(
            date ?? QuickTime.start(now: now, calendar: calendar),
            minutes: minutes, calendar: calendar))
      }
    }

    private func cell(_ title: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(title)
          .font(.body.monospacedDigit())
          .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
          .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.7)
          .padding(.horizontal, 3)
          .frame(maxWidth: .infinity, minHeight: selectedDayPresets ? 51 : 46)
          .background(Color(.secondarySystemGroupedBackground))
          .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
          .overlay(alignment: .trailing) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .tint(.primary)
    }
  }

#endif

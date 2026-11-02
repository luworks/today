#if os(iOS)
  import One
  import TodayCore
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  extension View {
    /// A switch draws about 2 points wider than its layout box on its trailing side, so in a row with hand-set margins it
    /// ends past the text and divider edge. This pulls it back so its visible edge sits on the same margin.
    func switchOnRowMargin() -> some View { offset(x: -2.5) }
  }

  /// One alarm in the list, as Clock draws it: a big light time with a small AM/PM, the label and repeat under it,
  /// and a green switch. Disabled alarms are gray.
  struct AlarmRow: View {
    @Bindable var alarm: OneAlarm
    var state: AlarmLiveState?
    let alarms: any AlarmService
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.modelContext) private var context
    @Environment(PlannerActions.self) private var actions
    var onEdit: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var timeSize = 48
    @ScaledMetric(relativeTo: .title) private var suffixSize = 26

    private var parts: (time: String, suffix: String?) {
      AlarmPlan.timeParts(hour: alarm.hour, minute: alarm.minute, locale: presentation.locale)
    }

    private var isRinging: Bool { state == .ringing }

    var body: some View {
      HStack(spacing: 12) {
        Button(action: onEdit) {
          VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              Text(parts.time)
                .font(.system(size: timeSize, weight: .light).monospacedDigit())
              if let suffix = parts.suffix {
                Text(suffix).font(.system(size: suffixSize, weight: .regular))
              }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(subtitle)
              .font(.callout)
          }
          .foregroundStyle(alarm.isOn ? Color.primary : Color.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(parts.time) \(parts.suffix ?? ""), \(subtitle)")
        .accessibilityIdentifier("alarm.row")

        if isRinging {
          Button("Stop") { if let id = alarm.alarmKitID { alarms.stop(id) } }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.orange)
            .accessibilityIdentifier("alarm.stop")
        } else {
          Toggle(
            "Alarm on",
            isOn: Binding(
              get: { alarm.isOn },
              set: { on in
                let before = alarm.activitySnapshot
                if on && !alarm.isOn {
                  alarm.createdAt = presentation.now
                  alarm.alarmKitSignature = nil
                }
                alarm.isOn = on
                if (try? context.save()) != nil {
                  actions.recordChange(alarm, from: before, context: context)
                }
                Task { await alarms.sync(context) }
              })
          )
          .labelsHidden()
          .tint(Color(.systemGreen))
          .switchOnRowMargin()
          .accessibilityLabel("\(parts.time) \(parts.suffix ?? "") \(subtitle)")
          .accessibilityIdentifier("alarm.toggle")
        }
      }
      .padding(.vertical, 2)
      .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
    }

    /// "Alarm, Every day"; says so while the alarm rings or is snoozing.
    private var subtitle: String {
      let text = AlarmPlan.rowSubtitle(
        label: alarm.label, weekdays: alarm.weekdays, calendar: presentation.calendar)
      switch state {
      case .ringing: return text + ", Ringing"
      case .snoozing: return text + ", Snoozed"
      default: return text
      }
    }
  }

  /// Add Alarm / Edit Alarm, after Clock's sheet: a round close button, the title and an orange round check; a full-width
  /// wheel; the Label as its own text-field card; a card with Repeat and the seven weekday circles; a card with Sound, Snooze
  /// and Snooze Duration (rarely changed, so last); and a red Delete Alarm when editing.
  package struct AlarmEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PlannerActions.self) private var actions
    @Environment(UndoToast.self) private var toast
    private let alarms: any AlarmService
    private let soundPreview: any SoundPreviewing
    private let runtime: PlannerRuntime
    private let onCreated: (OneAlarm, ModelContext) -> Void
    let alarm: OneAlarm?

    @State private var time: Date
    /// The minute wheel's step: 5 (00, 05 … 55), or 1 when the alarm being edited is not on a five-minute mark, so
    /// opening and saving it never moves its minute (`AlarmPlan.minuteStep`).
    @State private var minuteStep: Int
    @State private var label: String
    @State private var weekdays: Set<Int>
    @State private var snooze: Bool
    @State private var sound: String
    @State private var pendingAlarm: OneAlarm?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var snoozeMinutes: Int
    @FocusState private var labelFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let snoozeChoices = AlarmPlan.snoozeChoices

    package init(
      alarm: OneAlarm? = nil,
      alarms: any AlarmService, soundPreview: any SoundPreviewing,
      runtime: PlannerRuntime, defaults: UserDefaults,
      onCreated: @escaping (OneAlarm, ModelContext) -> Void
    ) {
      self.alarm = alarm
      self.alarms = alarms
      self.soundPreview = soundPreview
      self.runtime = runtime
      self.onCreated = onCreated
      // A new alarm starts at the next five-minute mark (10:52 → 10:55), so it still rings today when saved straight away.
      _time = State(
        initialValue: alarm.map {
          runtime.calendar.date(
            bySettingHour: $0.hour, minute: $0.minute, second: 0, of: runtime.now())
            ?? runtime.now()
        } ?? AlarmPlan.nextFiveMinutes(after: runtime.now(), calendar: runtime.calendar))
      _minuteStep = State(initialValue: AlarmPlan.minuteStep(forAlarmMinute: alarm?.minute))
      _label = State(initialValue: alarm?.label ?? "")
      _weekdays = State(initialValue: Set(alarm?.weekdays ?? []))
      // A new alarm starts like one made in the chat or by Siri (Settings > Alarms); an existing one keeps its own.
      let fresh = AlarmPlan.newAlarmDefaults(defaults)
      _snooze = State(initialValue: alarm?.snooze ?? fresh.snooze)
      _sound = State(initialValue: alarm?.sound ?? fresh.sound)
      _snoozeMinutes = State(
        initialValue: AlarmPlan.snoozeMinutes(nearest: alarm?.snoozeMinutes ?? fresh.snoozeMinutes))
    }

    /// The wheel works in minutes of the day; the editor keeps a date.
    private var wheelMinutes: Binding<Int> {
      Binding(
        get: {
          let c = runtime.calendar.dateComponents([.hour, .minute], from: time)
          return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        },
        set: { minutes in
          time =
            runtime.calendar.date(
              bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: time) ?? time
        })
    }

    package var body: some View {
      NavigationStack {
        ScrollView {
          VStack(spacing: 0) {
            header
            TimeWheelPicker(
              minutes: wheelMinutes, adaptiveMinutes: true, minuteStep: minuteStep,
              locale: runtime.locale
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 19)
            .padding(.top, 14)
            .accessibilityIdentifier("alarm.time")
            labelCard.padding(.top, 20)
            repeatCard.padding(.top, 20)
            optionsCard.padding(.top, 33)
            if let alarm { deleteButton(alarm).padding(.top, 33) }
          }
          .padding(.bottom, 30)
        }
        .disabled(saving)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
      }
      .environment(\.calendar, runtime.calendar)
      .environment(\.locale, runtime.locale)
      .environment(\.timeZone, runtime.calendar.timeZone)
      .presentationDetents([.large])
      .interactiveDismissDisabled(saving)
      .alert(
        "Couldn’t Update Alarm",
        isPresented: Binding(
          get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
    }

    // MARK: Header

    private var header: some View {
      ZStack {
        Text(alarm == nil ? "Add Alarm" : "Edit Alarm")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        HStack {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: 44, height: 44)
              .background(Color(.tertiarySystemFill), in: Circle())
              .contentShape(Circle())
          }
          .disabled(saving)
          .accessibilityLabel("Cancel")
          Spacer()
          Button(action: save) {
            Image(systemName: "checkmark")
              .font(.system(size: 19, weight: .semibold))
              .foregroundStyle(Color(.systemOrange).contrastForeground(for: colorScheme))
              .frame(width: 44, height: 44)
              .background(Color(.systemOrange), in: Circle())
              .contentShape(Circle())
          }
          .disabled(saving)
          .accessibilityLabel("Save")
          .accessibilityIdentifier("alarm.save")
        }
      }
      .padding(.horizontal, 19)
      .padding(.top, 16)
      .buttonStyle(.plain)
    }

    // MARK: Cards

    private var repeatCard: some View {
      Card {
        Row {
          Text("Repeat")
          Spacer()
          Text(AlarmPlan.repeatValue(weekdays: weekdays.sorted(), calendar: runtime.calendar))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alarm.repeat")
        Divider().padding(.horizontal, 18)
        HStack(spacing: 8) {
          ForEach(AlarmQuickPicks.RepeatPreset.allCases, id: \.self) { preset in
            let isOn = AlarmQuickPicks.RepeatPreset.matching(weekdays) == preset
            QuickChip(title: AlarmPlan.repeatValue(weekdays: Array(preset.weekdays)), isOn: isOn) {
              weekdays = isOn ? [] : preset.weekdays
            }
            .accessibilityIdentifier("alarm.repeat.\(preset.rawValue)")
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        HStack(spacing: 0) {
          ForEach(AlarmPlan.orderedWeekdays(), id: \.self) { day in
            DayCircle(day: day, isOn: weekdays.contains(day)) {
              if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
            }
            if day != AlarmPlan.orderedWeekdays().last { Spacer(minLength: 0) }
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
      }
    }

    /// The name gets its own card right under the time: the whole card is a text field, so it reads as a place to type.
    private var labelCard: some View {
      Card {
        Row {
          Image(systemName: "pencil")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(.systemOrange))
            .accessibilityHidden(true)
          TextField("Label", text: $label, prompt: Text("What’s this alarm for?"))
            .focused($labelFocused)
            .submitLabel(.done)
            .accessibilityLabel("Label")
            .accessibilityIdentifier("alarm.label")
          if !label.isEmpty {
            Button {
              label = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear Label")
          }
        }
        .onTapGesture { labelFocused = true }
        if let alarm, !alarm.note.isEmpty {
          Divider().padding(.horizontal, 18)
          Row {
            Text(alarm.note).foregroundStyle(.secondary).accessibilityIdentifier("alarm.notes")
          }
        }
      }
    }

    /// Sound and snooze: rarely changed, so they sit below Repeat.
    private var optionsCard: some View {
      Card {
        NavigationLink {
          SoundScreen(sound: $sound, preview: soundPreview).performanceDestination("alarm.sound")
        } label: {
          Row {
            Text("Sound").foregroundStyle(.primary)
            Spacer()
            Text(sound.isEmpty ? "Default" : sound).foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color(.tertiaryLabel))
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("alarm.sound")
        .performanceNavigationAction("alarm.sound")
        Divider().padding(.horizontal, 18)
        Row {
          Text("Snooze")
          Spacer()
          Toggle("Snooze", isOn: $snooze.animation(.snappy))
            .labelsHidden()
            .tint(Color(.systemGreen))
            .switchOnRowMargin()
            .accessibilityIdentifier("alarm.snooze")
        }
        if snooze {
          Divider().padding(.horizontal, 18)
          Row {
            Text("Snooze Duration")
            Spacer()
            Menu {
              Picker("Snooze Duration", selection: $snoozeMinutes) {
                ForEach(Self.snoozeChoices, id: \.self) { Text("\($0) min").tag($0) }
              }
            } label: {
              Text("\(snoozeMinutes) min").foregroundStyle(Color(.systemOrange))
            }
            .accessibilityIdentifier("alarm.snoozeDuration")
          }
        }
      }
    }

    private func deleteButton(_ alarm: OneAlarm) -> some View {
      Button(role: .destructive) {
        if actions.delete(alarm, context: context, toast: toast) {
          dismiss()
        } else {
          errorMessage =
            toast.message ?? "The alarm could not be fully updated. Keep it open and retry."
        }
      } label: {
        Text("Delete Alarm")
          .frame(maxWidth: .infinity, minHeight: 47)
          .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
      }
      .padding(.horizontal, 19)
      .disabled(saving)
      .accessibilityIdentifier("alarm.delete")
    }

    private func save() {
      guard !saving else { return }
      if let alarm, alarm.isDeleted || alarm.modelContext !== context {
        errorMessage = AlarmActions.Failure.stale.localizedDescription
        return
      }
      saving = true
      let c = runtime.calendar.dateComponents([.hour, .minute], from: time)
      let before = alarm?.snapshot()
      let target = alarm ?? pendingAlarm ?? OneAlarm(hour: 0, minute: 0)
      if alarm == nil { pendingAlarm = target }
      target.hour = c.hour ?? 7
      target.minute = c.minute ?? 0
      target.label = label.trimmingCharacters(in: .whitespaces)
      target.weekdays = weekdays.sorted()
      target.snooze = snooze
      target.sound = sound
      target.snoozeMinutes = snoozeMinutes
      target.isOn = true
      target.createdAt = runtime.now()  // a one-time alarm counts from the last save
      target.alarmKitSignature = nil  // forces a reschedule of exactly this alarm
      Task { @MainActor in
        defer { saving = false }
        do {
          try await alarms.commit(target, context: context)
          if let before {
            actions.recordChange(target, from: before.activitySnapshot, context: context)
          } else {
            onCreated(target, context)
          }
          dismiss()
        } catch {
          // A new unsaved row may have been removed after a failed disk write.
          // Retain its system identity, including when cancellation compensation failed.
          if let before {
            // Also protect the visible row if reading its saved state failed.
            let recoverySignature = target.alarmKitSignature
            target.restoreSettings(from: before)
            target.alarmKitSignature = recoverySignature
          } else {
            pendingAlarm = target.snapshot()
          }
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// A rounded group like Clock's: one card, rows separated by hairlines.
  private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
      VStack(spacing: 0) { content }
        .background(
          Color(.secondarySystemGroupedBackground),
          in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .padding(.horizontal, 19)
    }
  }

  /// One 47-point row with Clock's 18-point text inset.
  private struct Row<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
      HStack { content }
        .font(.body)
        .padding(.horizontal, 18)
        .frame(minHeight: 47)
        .contentShape(Rectangle())
    }
  }

  /// A small capsule for a quick pick; outlined in orange when it is what the alarm has now.
  private struct QuickChip: View {
    let title: String
    var isOn = false
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(tint)
          .lineLimit(1)
          .padding(.horizontal, 12)
          .frame(minHeight: 32)
          .background(Color(.tertiarySystemFill), in: Capsule())
          .overlay {
            if isOn { Capsule().strokeBorder(Color(.systemOrange), lineWidth: 1.5) }
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isOn ? .isSelected : [])
    }
  }

  /// A weekday circle: gray, orange when the alarm repeats that day. Reads as "Every Monday".
  private struct DayCircle: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    let day: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
      let name = "Every " + presentation.calendar.weekdaySymbols[day - 1]
      Button(action: action) {
        Text(presentation.calendar.veryShortWeekdaySymbols[day - 1])
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(
            isOn ? Color(.systemOrange).contrastForeground(for: colorScheme) : Color.primary
          )
          .frame(width: 32, height: 32)
          .background(isOn ? Color(.systemOrange) : Color(.tertiarySystemFill), in: Circle())
          .frame(width: 40, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
      .accessibilityAddTraits(isOn ? .isSelected : [])
      .accessibilityIdentifier("alarm.day.\(day)")
    }
  }

  /// Sound: the system alarm sound and the app's own tones, with a check mark on the chosen one. Tapping a tone plays it.
  package struct SoundScreen: View {
    @Binding var sound: String
    @Environment(\.dismiss) private var dismiss

    private let preview: any SoundPreviewing

    package init(sound: Binding<String>, preview: any SoundPreviewing) {
      self.preview = preview
      _sound = sound
    }

    package var body: some View {
      List {
        Section {
          row(title: "Default", value: "", subtitle: "The standard alarm sound")
        }
        Section("Tones") {
          ForEach(AlarmSound.all) { tone in
            row(title: tone.name, value: tone.name, subtitle: nil)
          }
        }
      }
      .navigationTitle("Sound")
      .navigationBarTitleDisplayMode(.inline)
      .onDisappear { preview.stop() }
    }

    private func row(title: String, value: String, subtitle: String?) -> some View {
      Button {
        sound = value
        if let tone = AlarmSound.named(value) { preview.play(tone) } else { preview.stop() }
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
          }
          Spacer()
          if sound == value {
            Image(systemName: "checkmark").foregroundStyle(Color(.systemOrange)).fontWeight(
              .semibold)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityAddTraits(sound == value ? .isSelected : [])
    }
  }

#endif

#if os(iOS)
  import TodayCore
  import TodayPlatform
  import One
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Create or edit an event Today keeps itself (Calendar access off, or a UI test). With Calendar access on, a new
  /// event and an existing one both open in Apple's own Edit Event (`NativeEvents.edit`).
  package struct EventEditor: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?

    let event: OneEvent?
    private let calendar: any CalendarService
    private let actions: PlannerActions
    private let ledger: Ledger
    private let alarms: any AlarmService

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatRule: RepeatRule?
    @State private var reminder: Int?
    @State private var ringsAsAlarm: Bool
    @State private var location: String
    @State private var url: String
    @State private var busy: Bool
    @State private var note: String
    @FocusState private var titleFocused: Bool
    /// Where a new event starts: the next full hour today, or 9:00 on the chosen day.
    private let defaultStart: Date

    /// The next full hour today, or 9:00 on another day.
    package static func defaultStart(for day: Date, now: Date, calendar cal: Calendar) -> Date {
      let base =
        cal.isDate(day, inSameDayAs: now)
        ? now : (cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)
      return cal.nextDate(
        after: base, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? base
    }

    /// `start` / `end`: a new event at a slot picked on the 2 Day grid (instead of the default time on `day`).
    package init(
      event: OneEvent? = nil, day: Date? = nil, start slotStart: Date? = nil,
      end slotEnd: Date? = nil,
      calendar: any CalendarService, actions: PlannerActions, ledger: Ledger,
      alarms: any AlarmService, presentation: PlannerPresentation
    ) {
      self.actions = actions
      self.ledger = ledger
      self.alarms = alarms
      self.calendar = calendar
      self.event = event
      let rounded =
        slotStart
        ?? Self.defaultStart(
          for: day ?? presentation.now, now: presentation.now, calendar: presentation.calendar)
      defaultStart = rounded
      let start = event?.start ?? rounded
      _title = State(initialValue: event?.title ?? "")
      _isAllDay = State(initialValue: event?.isAllDay ?? false)
      _start = State(initialValue: start)
      _end = State(
        initialValue: event == nil
          ? slotEnd
            ?? start.addingTimeInterval(
              TimeInterval(Preferences.newEventMinutes(presentation.defaults) * 60))
          : start.addingTimeInterval(TimeInterval((event?.durationMinutes ?? 60) * 60)))
      _repeatRule = State(initialValue: event?.repeats)
      _reminder = State(
        initialValue: event == nil
          ? Preferences.newEventAlertMinutes(presentation.defaults) : event?.reminderOffsetMinutes)
      _ringsAsAlarm = State(initialValue: event?.ringsAsAlarm ?? false)
      _location = State(initialValue: event?.location ?? "")
      _url = State(initialValue: event?.url ?? "")
      _busy = State(initialValue: event?.busy ?? true)
      _note = State(initialValue: event?.note ?? "")
    }

    package var body: some View {
      Group {
        if event == nil && calendar.usesNativeEditor,
          let native = calendar as? any NativeCalendarService
        {
          // Calendar access is on: a new event is made with Apple's own editor and lives in the system calendar.
          NativeEventEditor(identifier: nil, start: defaultStart, calendar: native)
            .ignoresSafeArea()
        } else {
          form
        }
      }
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
    }

    private var form: some View {
      NavigationStack {
        Form {
          Section {
            TextField("Title", text: $title)
              .font(.headline)
              .focused($titleFocused)
              .accessibilityIdentifier("event.title")
            TextField("Location", text: $location)
              .accessibilityIdentifier("event.location")
          }
          Section {
            Toggle("All-day", isOn: $isAllDay.animation())
            DatePicker(
              "Starts", selection: startKeepingLength,
              displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
            DatePicker(
              "Ends", selection: $end, in: start...,
              displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
            Picker(selection: $repeatRule) {
              Text("Never").tag(RepeatRule?.none)
              ForEach(RepeatRule.choices(including: repeatRule), id: \.self) {
                Text($0.label).tag(RepeatRule?.some($0))
              }
            } label: {
              Text("Repeat")
            }
          }
          Section {
            Picker(selection: $reminder) {
              ForEach(ReminderOffset.choices, id: \.0) { label, value in Text(label).tag(value) }
            } label: {
              Label("Remind me", systemImage: "bell")
            }
            if alarms.isAvailable, reminder != nil {
              Toggle(isOn: $ringsAsAlarm) { Label("Ring as alarm", systemImage: "alarm") }
            }
            Picker(selection: $busy) {
              Text("Busy").tag(true)
              Text("Free").tag(false)
            } label: {
              Label("Show As", systemImage: "circle.lefthalf.filled")
            }
          }
          Section("Details") {
            TextField("URL", text: $url)
              .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityIdentifier("event.url")
            TextField("Notes", text: $note, axis: .vertical)
              .accessibilityIdentifier("event.notes")
          }
          if let event {
            Section {
              Button(
                event.repeats == nil ? "Delete event" : "Delete all occurrences", role: .destructive
              ) {
                let backup = event.copy()
                guard calendar.delete(event) else {
                  toast?.showNotice(
                    "Couldn't delete “\(event.title)” from Calendar, so it was kept.")
                  dismiss()
                  return
                }
                ledger.record(
                  .deleted, kind: "event", title: backup.title,
                  before: plannerDayLabel(backup.start, runtime: presentation.runtime),
                  context: context)
                context.delete(event)
                toast?.show("Deleted “\(backup.title)”") {
                  backup.externalID = calendar.save(backup)
                  withAnimation(.snappy) { context.insert(backup) }
                  try? context.save()
                }
                dismiss()
              }
            }
          }
        }
        .onAppear { if event == nil { titleFocused = true } }
        .performanceDestination("event.editor")
        .navigationTitle(event == nil ? "New event" : "Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: save)
              .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      }
    }

    /// Moving the start moves the end with it, so the event keeps its length, like Apple Calendar. Done in the setter, from the
    /// current values: an `onChange(of: start)` adjustment lost minutes when the wheel sent several changes in a row.
    private var startKeepingLength: Binding<Date> {
      Binding(
        get: { start },
        set: { new in
          end = new.addingTimeInterval(end.timeIntervalSince(start))
          start = new
        })
    }

    private func save() {
      let cal = presentation.calendar
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      var s = start
      var minutes = max(5, Int(end.timeIntervalSince(start) / 60))
      if isAllDay {
        s = cal.startOfDay(for: start)
        let days = (cal.dateComponents([.day], from: s, to: cal.startOfDay(for: end)).day ?? 0) + 1
        minutes = max(1, days) * 1440
      }
      let e = event ?? OneEvent(title: trimmed, start: s, durationMinutes: minutes)
      e.title = trimmed
      e.start = s
      e.durationMinutes = minutes
      e.isAllDay = isAllDay
      e.repeatRule = repeatRule?.rawValue
      e.reminderOffsetMinutes = reminder
      e.ringsAsAlarm = ringsAsAlarm && reminder != nil
      let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
      e.location = place.isEmpty ? nil : place
      let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
      e.url = link.isEmpty ? nil : link
      // nil = never chosen (Busy, EventKit's default); only an actual choice is written.
      if event?.busy != nil || !busy { e.busy = busy }
      e.note = note
      if event == nil { context.insert(e) }
      do { try context.save() } catch {
        if event == nil { context.delete(e) }
        toast?.showNotice("Couldn’t save the event. " + error.localizedDescription)
        return
      }
      if calendar.isOn { e.externalID = calendar.save(e) ?? e.externalID }
      if event == nil {
        ledger.record(
          .created, kind: "event", title: e.title,
          after: plannerDayLabel(e.start, runtime: presentation.runtime), context: context)
      }
      dismiss()
    }
  }

#endif

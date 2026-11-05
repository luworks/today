#if os(iOS)
  import One
  import TodayDesignSystem
  import TodayCore
  import TodayPlatform
  import SwiftUI
  import SwiftData

  /// Create or edit a task. Edits are held locally and written back on Save.
  /// Planned time and deadline are separate: changing one never changes the other.
  package struct TaskEditor: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?
    @Query(sort: \OneList.order) private var lists: [OneList]

    private let actions: PlannerActions
    private let ledger: Ledger
    private let reminders: any ReminderService
    private let alarms: any AlarmService
    let task: OneTask?

    @State private var title: String
    @State private var note: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var reminder: Int?
    @State private var listName: String
    @State private var tagsText: String
    @State private var flagged: Bool
    @State private var repeatRule: RepeatRule?
    @State private var checklist: [ChecklistItem]
    @State private var ringsAsAlarm: Bool
    @State private var detent: PresentationDetent = .height(366)
    @State private var advanced = false
    @State private var showsDatePicker = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedTask: OneTask?
    @State private var pendingEditReceipt: RemindersSync.Remote?
    @State private var baselineExternalID: String?
    @State private var pendingSync = false
    @State private var baseline: TaskSnapshot?
    @State private var newItem = ""
    @State private var addingList = false
    @State private var repeatDayDraft: RepeatDayDraft?
    @FocusState private var titleFocused: Bool

    package init(
      task: OneTask? = nil, actions: PlannerActions, ledger: Ledger, reminders: any ReminderService,
      alarms: any AlarmService, presentation: PlannerPresentation
    ) {
      self.actions = actions
      self.ledger = ledger
      self.reminders = reminders
      self.alarms = alarms
      self.task = task
      _baseline = State(initialValue: task.map { Ledger.snapshot(of: $0) })
      _baselineExternalID = State(initialValue: task?.externalID)
      _title = State(initialValue: task?.title ?? "")
      _note = State(initialValue: task?.note ?? "")
      _hasDue = State(initialValue: task?.due != nil)
      _due = State(
        initialValue: task?.due ?? presentation.calendar.startOfDay(for: presentation.now))
      _reminder = State(initialValue: task == nil ? 0 : task?.reminderOffsetMinutes)
      _listName = State(initialValue: task?.listName ?? "")
      _tagsText = State(initialValue: task?.tags.joined(separator: ", ") ?? "")
      _flagged = State(initialValue: task?.flagged ?? false)
      _repeatRule = State(initialValue: task?.repeats)
      _checklist = State(initialValue: task?.checklist ?? [])
      _ringsAsAlarm = State(initialValue: task?.ringsAsAlarm ?? false)
    }

    /// List names to pick from: My Lists, plus the task's current list if it has no OneList yet.
    private var knownLists: [String] {
      let names = lists.map(\.name)
      return listName.isEmpty || names.contains(listName) ? names : names + [listName]
    }

    package var body: some View {
      NavigationStack {
        Group {
          if advanced { details } else { compact }
        }
        .disabled(saving)
        .performanceDestination("reminder.editor")
        .navigationTitle(task == nil ? "New reminder" : "Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { if !saving { dismiss() } }.disabled(saving)
          }
          ToolbarItem(placement: .topBarLeading) {
            if advanced {
              Button("Quick edit") { if !saving { advanced = false } }.disabled(saving)
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
              .disabled(!canSave || saving)
              .accessibilityIdentifier("task.save")
          }
        }
        .toolbar(advanced ? .visible : .hidden, for: .navigationBar)
        .onAppear { if task == nil { titleFocused = true } }
        .alert(
          "Couldn’t Update Reminder",
          isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(saveError ?? "")
        }
        .sheet(isPresented: $addingList) {
          ListEditor(ledger: ledger, reminders: reminders) { created in listName = created.name }
            .environment(actions)
            .environment(presentation)
        }
        .sheet(item: $repeatDayDraft) { draft in
          RepeatWeekdayPicker(calendar: presentation.calendar, initialDays: draft.days) { days in
            repeatRule = .weeklyOn(days.sorted())
          }
        }
      }
      .presentationDetents(advanced ? [.large] : [.height(366), .large], selection: $detent)
      .onChange(of: advanced) { _, expanded in detent = expanded ? .large : .height(366) }
      .presentationDragIndicator(.hidden)
      .presentationCornerRadius(48)
      .interactiveDismissDisabled(saving)
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
    }

    private var details: some View {
      Form {
        Section {
          TextField("Title", text: $title, axis: .vertical)
            .font(.headline)
            .focused($titleFocused)
            .accessibilityIdentifier("task.title")
          TextField("Notes", text: $note, axis: .vertical)
            .lineLimit(2...6)
            .accessibilityIdentifier("task.note")
        }
        Section {
          ForEach($checklist) { $item in
            HStack {
              Button {
                item.done.toggle()
              } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(item.done ? Color.green : Color.secondary)
              }
              .buttonStyle(.borderless)
              TextField("Item", text: $item.title)
                .strikethrough(item.done)
            }
          }
          .onDelete { checklist.remove(atOffsets: $0) }
          HStack {
            Image(systemName: "plus").foregroundStyle(.secondary)
            TextField("Add checklist item", text: $newItem)
              .onSubmit(addItem)
              .submitLabel(.next)
          }
        } header: {
          Text("Checklist")
        }
        Section {
          Toggle(isOn: $hasDue.animation()) {
            Label("Deadline", systemImage: "calendar.badge.exclamationmark")
          }
          if hasDue {
            DatePicker("Due", selection: $due)
          }
          Picker(selection: $repeatRule) {
            Text("Never").tag(RepeatRule?.none)
            ForEach(RepeatRule.choices(including: repeatRule), id: \.self) {
              Text($0.label).tag(RepeatRule?.some($0))
            }
          } label: {
            Label("Repeat", systemImage: "repeat")
          }
          Button("Choose weekdays…", action: chooseRepeatDays)
            .accessibilityIdentifier("task.repeat.chooseDays")
        }
        if hasDue {
          Section {
            Picker(selection: $reminder) {
              ForEach(ReminderOffset.choices, id: \.0) { label, value in Text(label).tag(value) }
            } label: {
              Label("Remind me", systemImage: "bell")
            }
            if alarms.isAvailable, reminder != nil {
              Toggle(isOn: $ringsAsAlarm) { Label("Ring as alarm", systemImage: "alarm") }
            }
          } footer: {
            Text(
              ringsAsAlarm
                ? (alarms.authorization == .denied
                  ? "Alarms are turned off for Today in Settings, so this will only notify."
                  : "Rings like an alarm, even on Silent. Stopping it doesn't complete the task.")
                : "One notification at the reminder time.")
          }
        }
        Section {
          Picker(selection: $listName) {
            Text("Reminders").tag("")
            ForEach(knownLists, id: \.self) { Text(ListName.display($0)).tag($0) }
          } label: {
            Label("List", systemImage: "list.bullet")
          }
          .accessibilityIdentifier("task.list")
          Button {
            addingList = true
          } label: {
            Label("New list…", systemImage: "plus")
          }
          HStack {
            Label("Tags", systemImage: "number")
            TextField("work, errands", text: $tagsText)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
          }
          Toggle(isOn: $flagged) { Label("Flag", systemImage: "flag") }
        }
        if let task {
          Section {
            Button(task.isDone ? "Mark as not done" : "Mark done") {
              complete(task)
            }
            Button("Delete task", role: .destructive) {
              delete(task)
            }
          }
        }
      }
      .scrollDismissesKeyboard(.interactively)
    }

    private func chooseRepeatDays() {
      titleFocused = false
      let days: Set<Int>
      switch repeatRule {
      case .weeklyOn(let selected): days = Set(selected)
      case .weekdays: days = [2, 3, 4, 5, 6]
      case .daily: days = Set(1...7)
      case .weekly:
        days = [presentation.calendar.component(.weekday, from: hasDue ? due : presentation.now)]
      default: days = []
      }
      repeatDayDraft = RepeatDayDraft(days: days)
    }

    private var selectedDate: Date? { hasDue ? due : nil }

    private var selectedHasTime: Bool {
      guard let selectedDate else { return false }
      let parts = presentation.calendar.dateComponents([.hour, .minute], from: selectedDate)
      return parts.hour != 0 || parts.minute != 0
    }

    private var compact: some View {
      VStack(spacing: 16) {
        HStack(spacing: 0) {
          icon("xmark", label: "Cancel") { dismiss() }
            .accessibilityIdentifier("task.cancel")
          Spacer(minLength: 8)
          Menu {
            Picker("Repeat", selection: $repeatRule) {
              Text("Never").tag(RepeatRule?.none)
              ForEach(RepeatRule.choices(including: repeatRule), id: \.self) {
                Text($0.label).tag(RepeatRule?.some($0))
              }
            }
            Button("Choose weekdays…", action: chooseRepeatDays)
              .accessibilityIdentifier("task.repeat.chooseDays")
          } label: {
            Image(systemName: "repeat").frame(width: 44, height: 44)
              .foregroundStyle(repeatRule == nil ? Color.secondary : Color.accentColor)
          }
          .accessibilityLabel(repeatRule.map { "Repeat, \($0.label)" } ?? "Repeat")
          .accessibilityIdentifier("task.repeat")
          Menu {
            Picker("Remind me", selection: $reminder) {
              ForEach(ReminderOffset.choices, id: \.0) { label, value in Text(label).tag(value) }
            }
            if alarms.isAvailable, reminder != nil {
              Toggle("Ring as alarm", isOn: $ringsAsAlarm)
            }
          } label: {
            Image(systemName: ringsAsAlarm ? "alarm" : "bell").frame(width: 44, height: 44)
              .foregroundStyle(reminder == nil ? Color.secondary : Color.primary)
          }.accessibilityLabel("Reminder and alarm options")
          Spacer(minLength: 8)
          Button(action: save) {
            Text("Save").font(.body.weight(.semibold))
              .frame(minWidth: 68, minHeight: 44)
              .foregroundStyle(
                canSave ? Color.accentColor.contrastForeground(for: colorScheme) : Color.secondary
              )
              .background(canSave ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(!canSave || saving)
          .accessibilityIdentifier("task.save")
        }
        .padding(.horizontal, 16)
        ScrollView {
          VStack(spacing: 0) {
            VStack(spacing: 0) {
              TextField("Title", text: $title, axis: .vertical)
                .font(.body)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .accessibilityIdentifier("task.title")
              Button {
                titleFocused = false
                showsDatePicker.toggle()
              } label: {
                HStack(spacing: 4) {
                  Text("Deadline").font(.caption.weight(.semibold))
                  if let selectedDate {
                    if selectedHasTime {
                      Text(
                        selectedDate.plannerFormatted(
                          .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute(),
                          runtime: presentation.runtime)
                      ).font(.subheadline)
                      Text(QuickTime.relative(selectedDate, now: presentation.now))
                        .font(.subheadline).opacity(0.8)
                    } else {
                      Text(
                        selectedDate.plannerFormatted(
                          .dateTime.weekday(.abbreviated).month(.abbreviated).day(),
                          runtime: presentation.runtime)
                      ).font(.subheadline)
                    }
                  } else {
                    Text("No date").font(.subheadline)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .foregroundStyle(
                  selectedDate == nil
                    ? Color(.label)
                    : (selectedHasTime
                      && (selectedDate.map { $0 <= presentation.now } ?? false)
                      ? Color.red.contrastForeground(for: colorScheme)
                      : Color.accentColor.contrastForeground(for: colorScheme))
                )
                .background(
                  selectedDate == nil
                    ? Color(.tertiarySystemFill)
                    : (selectedHasTime
                      && (selectedDate.map { $0 <= presentation.now } ?? false)
                      ? Color.red : Color.accentColor))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("task.when")
              if showsDatePicker {
                DatePicker(
                  "Date",
                  selection: Binding(
                    get: {
                      selectedDate
                        ?? QuickTime.start(
                          now: presentation.now,
                          calendar: presentation.calendar)
                    }, set: setSelectedDate)
                )
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                Button("Remove deadline") { hasDue = false }
                  .frame(minHeight: 44)
              }
              QuickTimeGrid(
                date: selectedDate, now: presentation.now,
                calendar: presentation.calendar, set: setSelectedDate)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
              if let task {
                icon("trash", label: "Delete task") { delete(task) }
                Spacer()
              }
              icon(flagged ? "flag.fill" : "flag", label: flagged ? "Unflag" : "Flag") {
                flagged.toggle()
              }
              Spacer()
              if let task {
                icon(
                  task.isDone ? "arrow.uturn.backward" : "checkmark",
                  label: task.isDone ? "Mark as not done" : "Mark done"
                ) { complete(task) }
                Spacer()
              }
              icon("ellipsis", label: "More options") {
                titleFocused = false
                advanced = true
              }
              .accessibilityIdentifier("task.more")
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
      }
      .padding(.top, 16)
      .background(Color(.systemGroupedBackground))
      .disabled(saving)
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: symbol).font(.title3)
          .frame(width: 44, height: 44)
          .background(Color(.secondarySystemGroupedBackground), in: Circle())
          .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
      }
      .buttonStyle(.plain)
      .tint(.primary)
      .accessibilityLabel(label)
    }

    private func setSelectedDate(_ date: Date) {
      titleFocused = false
      due = date
      hasDue = true
    }

    private var cleanedTags: [String] {
      tagsText.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(
          in: CharacterSet(charactersIn: "#"))
      }.filter { !$0.isEmpty }
    }

    private var draft: TaskSnapshot {
      TaskSnapshot(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines), note: note,
        isDone: baseline?.isDone ?? false, doneAt: baseline?.doneAt,
        durationMinutes: baseline?.durationMinutes ?? 25, due: hasDue ? due : nil,
        createdAt: baseline?.createdAt ?? presentation.now, reminderOffsetMinutes: reminder,
        listName: listName, tags: cleanedTags, flagged: flagged, repeatRule: repeatRule?.rawValue,
        checklist: checklist, ringsAsAlarm: ringsAsAlarm, reminderAlert: baseline?.reminderAlert)
    }

    private var workingTask: OneTask? { task ?? savedTask }

    private var canSave: Bool {
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (workingTask == nil || draft != baseline
          || !newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingSync)
    }

    private func complete(_ task: OneTask) {
      guard !saving, !task.isDeleted, task.modelContext != nil else { return }
      let wasDone = task.isDone
      actions.toggleDone(task, context: context, toast: toast)
      if task.isDone != wasDone {
        dismiss()
      } else {
        saveError = "The reminder was not updated. Your draft is still here. Please try again."
      }
    }

    private func delete(_ task: OneTask) {
      guard !saving else { return }
      guard !task.isDeleted, task.modelContext != nil,
        task.externalID == baselineExternalID, Ledger.snapshot(of: task) == baseline
      else {
        saveError = "This reminder changed outside the editor. Close and reopen it before deleting."
        return
      }
      do {
        try actions.deleteConfirmed(task, context: context, toast: toast)
        dismiss()
      } catch { saveError = error.localizedDescription + " Your draft is still here." }
    }

    private func addItem() {
      let t = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !t.isEmpty else { return }
      checklist.append(ChecklistItem(title: t))
      newItem = ""
    }

    private func save() {
      guard !saving else { return }
      if workingTask != nil, draft == baseline,
        newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !pendingSync
      {
        dismiss()
        return
      }
      if let task = workingTask {
        guard !task.isDeleted, task.modelContext != nil, task.externalID == baselineExternalID,
          Ledger.snapshot(of: task) == baseline
        else {
          saveError =
            "This reminder changed outside the editor. Close and reopen it to see the latest version. Your changes have not been applied."
          return
        }
      }
      addItem()
      let creating = workingTask == nil
      let t = workingTask ?? OneTask(title: "")
      let previous = baseline
      var accepted = pendingEditReceipt
      if let previous, !creating,
        RemindersSync.fingerprint(of: draft) != RemindersSync.fingerprint(of: previous)
          || pendingEditReceipt != nil
      {
        do { accepted = try reminders.commitEdit(t, draft: draft, expected: previous) } catch {
          saveError =
            "Apple Reminders was not updated. Your draft is still here. "
            + error.localizedDescription
          return
        }
      }
      t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      t.note = note
      // A repeating reminder needs a date (Apple Reminders refuses one without): like Apple's app, today.
      t.due =
        hasDue
        ? due : (repeatRule == nil ? nil : presentation.calendar.startOfDay(for: presentation.now))
      t.reminderOffsetMinutes = reminder
      t.listName = listName
      t.tags = cleanedTags
      t.flagged = flagged
      t.repeatRule = repeatRule?.rawValue
      t.checklist = checklist.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
      t.ringsAsAlarm = ringsAsAlarm
      if creating {
        t.createdAt = presentation.now
        context.insert(t)
      }
      do { try context.save() } catch {
        if creating { context.delete(t) }
        if let accepted {
          baseline = Ledger.snapshot(of: t)
          pendingEditReceipt = accepted
          pendingSync = true
          saveError =
            "Apple Reminders accepted the change, but Today couldn’t save its copy. Tap Save to retry the local save. "
            + error.localizedDescription
        } else {
          if let previous { restore(previous, to: t) }
          saveError = "Your draft was not saved. Please try again. " + error.localizedDescription
        }
        return
      }
      if creating {
        savedTask = t
        ledger.record(
          .created, task: t, title: t.title,
          after: ledger.timeLabel(t.due, none: ""), context: context)
      }
      baseline = Ledger.snapshot(of: t)
      baselineExternalID = t.externalID
      reminders.didPersistEdit(t, accepted: accepted)
      dismiss()
    }

    private func restore(_ value: TaskSnapshot, to task: OneTask) {
      task.title = value.title
      task.note = value.note
      task.durationMinutes = value.durationMinutes
      task.due = value.due
      task.reminderOffsetMinutes = value.reminderOffsetMinutes
      task.listName = value.listName
      task.tags = value.tags
      task.flagged = value.flagged
      task.repeatRule = value.repeatRule
      task.checklist = value.checklist
      task.ringsAsAlarm = value.ringsAsAlarm
      task.reminderAlert = value.reminderAlert
    }
  }

  private struct RepeatDayDraft: Identifiable {
    let id = UUID()
    let days: Set<Int>
  }

  private struct RepeatWeekdayPicker: View {
    @Environment(\.dismiss) private var dismiss
    let calendar: Calendar
    let onSave: (Set<Int>) -> Void
    @State private var days: Set<Int>

    init(calendar: Calendar, initialDays: Set<Int>, onSave: @escaping (Set<Int>) -> Void) {
      self.calendar = calendar
      self.onSave = onSave
      _days = State(initialValue: initialDays)
    }

    var body: some View {
      let orderedDays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
      NavigationStack {
        List(orderedDays, id: \.self) { day in
          Toggle(
            calendar.weekdaySymbols[day - 1],
            isOn: Binding(
              get: { days.contains(day) },
              set: { selected in
                if selected { days.insert(day) } else { days.remove(day) }
              })
          )
          .accessibilityIdentifier("task.repeat.weekday.\(day)")
        }
        .navigationTitle("Repeat on")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              onSave(days)
              dismiss()
            }
            .disabled(days.isEmpty)
            .accessibilityIdentifier("task.repeat.days.done")
          }
        }
      }
    }
  }

#endif

#if os(iOS)
  import One
  import SwiftUI
  import SwiftData
  import TodayCore
  import TodayPlatform
  import TodayDesignSystem

  /// Optional Today-only attention commands; source deletion stays with the existing row owner.
  package struct TodayRowAttention {
    package var settle: (() -> Void)?
    package var canDelete = true

    package init(settle: (() -> Void)?, canDelete: Bool = true) {
      self.settle = settle
      self.canDelete = canDelete
    }

    @ViewBuilder package func swipeButtons(delete: @escaping () -> Void) -> some View {
      // SwiftUI lays trailing actions out from the outside edge: Delete stays rightmost.
      if canDelete {
        Button(action: delete) { Label("Delete", systemImage: "trash") }.tint(.red)
      }
      if let settle {
        Button(action: settle) { Label("Settle", systemImage: "checkmark.circle.fill") }.tint(
          .indigo)
      }
    }

    @ViewBuilder package var menu: some View {
      if let settle {
        Button(action: settle) { Label("Settle", systemImage: "checkmark.circle.fill") }
          .accessibilityHint("Hides this item in Today only. Alerts stay unchanged.")
      }
    }
  }

  package struct TodayItemSurface: ViewModifier {
    package var enabled: Bool
    package init(enabled: Bool) { self.enabled = enabled }
    @ViewBuilder package func body(content: Content) -> some View {
      if enabled {
        content
          .padding(.horizontal, 8)
          .contentShape(Rectangle())
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
      } else {
        content
      }
    }
  }

  /// Events are fixed: no move actions here. `start` is the occurrence shown (repeating events).
  package struct EventRow: View {
    private let calendar: any CalendarService
    private let travelProvider: any TravelTimeProviding
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.modelContext) private var context
    package let event: OneEvent
    package var start: Date? = nil
    /// The list that holds this row asks "this event or the series?" for a repeating one (see `entryDeleteDialog`).
    @Binding package var pendingDelete: CalEntry?
    package let open: @MainActor (OneEvent) -> Void
    package var attention: TodayRowAttention?
    @AppStorage(SettingsKey.travelTime) private var travelOn = true

    package init(
      event: OneEvent, start: Date? = nil, pendingDelete: Binding<CalEntry?> = .constant(nil),
      open: @escaping @MainActor (OneEvent) -> Void, calendar: any CalendarService,
      travel: any TravelTimeProviding, attention: TodayRowAttention? = nil
    ) {
      self.calendar = calendar
      self.travelProvider = travel
      self.attention = attention
      self.open = open
      self.event = event
      self.start = start
      _pendingDelete = pendingDelete
    }

    private var detail: String {
      var parts: [String] = []
      if event.isAllDay {
        let days = max(1, event.durationMinutes / 1440)
        parts.append(days > 1 ? "\(days) days" : event.calendarName)
      } else {
        parts.append(DurationLabel.text(minutes: event.durationMinutes))
      }
      if let rule = event.repeats { parts.append("↻ " + rule.label) }
      return parts.joined(separator: " · ")
    }

    package var body: some View {
      HStack(
        alignment: attention == nil ? .center : .firstTextBaseline,
        spacing: attention == nil ? 10 : 0
      ) {
        if !event.isAllDay {
          TimeColumn(date: start ?? event.start, compact: attention != nil).dynamicTypeSize(
            ...(attention == nil ? DynamicTypeSize.accessibility5 : .xxxLarge))
        }
        CalendarBar(color: calendar.color(forExternalID: event.externalID) ?? Color.blue)
          .frame(height: attention == nil ? nil : 20)
          .modifier(AgendaIconSlot(enabled: attention != nil))
        VStack(alignment: .leading, spacing: 1) {
          TitleDetail(title: Text(event.title)) {
            Group {
              if attention != nil {
                Text(rowDetail)
              } else {
                Label(rowDetail, systemImage: "lock.fill")
                  .labelStyle(.titleAndIcon)
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .font(attention == nil ? Font.body : AgendaRowStyle.title)
      .modifier(TodayItemSurface(enabled: attention != nil))
      .onTapGesture { open(event) }

      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: attention == nil ? 1 : 0, leading: attention == nil ? 20 : 12,
          bottom: attention == nil ? 1 : 0, trailing: attention == nil ? 20 : 12)
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        plannerEventSpeech(
          title: event.title, start: start ?? event.start,
          end: (start ?? event.start).addingTimeInterval(event.duration), isAllDay: event.isAllDay,
          calendar: calendar.calendar(forExternalID: event.externalID)?.title ?? event.calendarName,
          runtime: presentation.runtime)
          + (travel.map { ". " + $0 } ?? "")
      )
      .accessibilityAddTraits(.isButton)
      .entryActions(
        entry, pendingDelete: $pendingDelete, open: { _ in open(event) },
        edit: { _ in open(event) }, calendar: calendar, attention: attention)
    }

    private var rowDetail: String { detail + (travel.map { " · " + $0 } ?? "") }

    /// "Drive 18 min · Leave by 14:20" when the event's Apple Calendar copy has a location (Today's own events keep none).
    private var travel: String? {
      guard travelOn, let id = event.externalID else { return nil }
      return travelProvider.label(
        eventID: id, start: start ?? event.start, isAllDay: event.isAllDay,
        place: calendar.place(forExternalID: id), now: presentation.now)
    }

    /// The same swipe and long-press actions as in the Calendar tab.
    private var entry: CalEntry {
      let begin = start ?? event.start
      return CalEntry(
        id: "r\(event.persistentModelID.hashValue)@\(begin.timeIntervalSince1970)",
        source: .local(event), title: event.title,
        start: begin, end: begin.addingTimeInterval(event.duration), isAllDay: event.isAllDay,
        color: calendar.color(forExternalID: event.externalID) ?? .blue,
        repeats: event.repeats != nil)
    }
  }

  /// Tasks flex: they can be moved, and only the circle completes them (like Apple Reminders).
  /// A reminder row. Today / Tomorrow in its menu change the reminder's one date.
  package struct TaskRow: View {
    @Environment(PlannerActions.self) private var actions
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?
    @Environment(\.dynamicTypeSize) private var typeSize
    package let task: OneTask
    package var showsTime = false
    /// The time in the time column.
    package var time: Date? = nil
    /// Add the list name to the detail line. Off inside a list, where it is the title.
    package var showsList = true
    /// Day view uses tighter insets.
    package var compact = false
    /// Set on the Today tab: the day the row sits on. The detail line then keeps at most two facts (see `RowSubtitle`).
    package var agendaDay: Date? = nil
    package var onDelete: (() -> Void)? = nil
    package var attention: TodayRowAttention?
    package let open: @MainActor (OneTask) -> Void

    package init(
      task: OneTask, showsTime: Bool = false, time: Date? = nil, showsList: Bool = true,
      compact: Bool = false, agendaDay: Date? = nil,
      onDelete: (() -> Void)? = nil, open: @escaping @MainActor (OneTask) -> Void,
      attention: TodayRowAttention? = nil
    ) {
      self.task = task
      self.showsTime = showsTime
      self.time = time
      self.showsList = showsList
      self.compact = compact
      self.agendaDay = agendaDay
      self.onDelete = onDelete
      self.attention = attention
      self.open = open
    }

    package var body: some View {
      HStack(
        alignment: attention == nil ? .center : .firstTextBaseline,
        spacing: attention == nil ? 10 : 0
      ) {
        if showsTime, let start = time ?? task.due {
          TimeColumn(date: start, compact: attention != nil).dynamicTypeSize(
            ...(attention == nil ? DynamicTypeSize.accessibility5 : .xxxLarge))
        }
        Button {
          actions.toggleDone(task, context: context, toast: toast)
        } label: {
          Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            .font(attention == nil ? .title3 : AgendaRowStyle.title)
            .foregroundStyle(task.isDone ? Color.green : Color.secondary)
            .frame(height: attention != nil && !typeSize.isAccessibilitySize ? 20 : nil)
            .frame(
              minWidth: attention == nil ? 24 : 44, minHeight: attention == nil ? 0 : 44,
              alignment: attention != nil && !typeSize.isAccessibilitySize ? .top : .center
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .modifier(AgendaIconSlot(enabled: attention != nil))
        .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
        .accessibilityLabel(task.isDone ? "Reopen \(task.title)" : "Complete \(task.title)")
        TitleDetail(title: title, hasDetail: detail != nil) {
          detailText
        }
        Spacer(minLength: 0)
        if task.flagged {
          Image(systemName: "flag.fill")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, attention == nil ? 0 : 6)
            .accessibilityLabel("Flagged")
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .font(attention == nil ? Font.body : AgendaRowStyle.title)
      .modifier(TodayItemSurface(enabled: attention != nil))
      .onTapGesture {
        PerformanceTrace.shared.beginPage("reminder.editor")
        open(task)
      }

      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: attention != nil ? 0 : (compact ? 1 : 4), leading: attention == nil ? 20 : 12,
          bottom: attention != nil ? 0 : (compact ? 1 : 4), trailing: attention == nil ? 20 : 12)
      )
      // Same gestures as Apple Reminders: tap the circle to complete, swipe left for Delete / Flag,
      // long-press for the menu. (Delete has an Undo toast.)
      .swipeActions(edge: .trailing, allowsFullSwipe: attention == nil) {
        if let attention {
          attention.swipeButtons(delete: deleteTask).labelStyle(.titleAndIcon)
          // Postpone in one swipe: the reminder's one date moves to tomorrow, keeping its time.
          Button {
            plan(tomorrow: true)
          } label: {
            Label("Tomorrow", systemImage: "sunrise")
          }
          .tint(.blue)
          .labelStyle(.titleAndIcon)
        } else {
          // Confirmed Today deletion must not let SwiftUI remove a row before the source accepts it.
          RowAction.delete(asksFirst: onDelete != nil) { deleteTask() }
          RowAction.flag(task.flagged) { withAnimation { task.flagged.toggle() } }
        }
      }
      .contextMenu {
        AskAIMenuButton(AskSubject(task: task))
        Button {
          PerformanceTrace.shared.beginPage("reminder.editor")
          open(task)
        } label: {
          Label("Show Details", systemImage: "info.circle")
        }
        // Today adds Settle to the same date commands every list has; it never replaces them.
        Button {
          task.flagged.toggle()
        } label: {
          Label(
            task.flagged ? "Remove Flag" : "Flag",
            systemImage: task.flagged ? "flag.slash" : "flag"
          )
        }
        Button {
          plan(tomorrow: false)
        } label: {
          Label("Today", systemImage: "calendar")
        }
        Button {
          plan(tomorrow: true)
        } label: {
          Label("Tomorrow", systemImage: "sunrise")
        }
        if task.due != nil {
          Button {
            actions.setDue(task, to: nil, context: context)
          } label: {
            Label("Unschedule", systemImage: "calendar.badge.minus")
          }
        }
        if let attention { Section { attention.menu } }
        if attention?.canDelete ?? true {
          Section {
            Button(role: .destructive, action: deleteTask) {
              Label("Delete", systemImage: "trash")
            }
          }
        }
      }
    }

    private func deleteTask() {
      if let onDelete { onDelete() } else { actions.delete(task, context: context, toast: toast) }
    }

    /// Today / Tomorrow from the menu: works out the new date on the task, then records it like any other move.
    private func plan(tomorrow: Bool) {
      let new = plannerMove(
        task, tomorrow: tomorrow, now: presentation.now, calendar: presentation.calendar)
      actions.setDue(task, to: new, context: context)
    }

    private var title: Text {
      Text(task.title)
        .strikethrough(task.isDone)
        .foregroundStyle(task.isDone ? .secondary : .primary)
    }

    @ViewBuilder private var detailText: some View {
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(
            plannerIsOverdue(task, now: presentation.now, calendar: presentation.calendar)
              ? Color.red : Color.secondary
          )
          .lineLimit(1)
      }
    }

    /// Most important first, so truncation drops the least useful bits: date, repeat, list, tags.
    private var detail: String? {
      if let agendaDay {
        let shown = showsTime ? (time ?? task.due) : nil
        return plannerRowSubtitle(
          .init(
            due: task.due,
            dueHasTime: plannerDueHasTime(task, calendar: presentation.calendar),
            shownTime: shown, repeats: task.repeats != nil,
            stepsDone: task.checklist.filter(\.done).count, stepsTotal: task.checklist.count,
            listName: showsList ? task.listName : ""),
          day: agendaDay, runtime: presentation.runtime)
      }
      var parts: [String] = []
      if let due = task.due {
        parts.append("Due " + plannerDayLabel(due, runtime: presentation.runtime))
      }
      if task.repeats != nil { parts.append("↻") }
      if !task.checklist.isEmpty {
        parts.append("\(task.checklist.filter(\.done).count)/\(task.checklist.count)")
      }
      if showsList, !task.listName.isEmpty { parts.append(ListName.display(task.listName)) }
      parts += task.tags.map { "#" + $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
  }

  /// An alarm in the day's schedule, so the whole day reads in one list.
  package struct AlarmMarkRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(PlannerActions.self) private var actions
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?
    private let open: @MainActor (OneAlarm) -> Void
    private let attention: TodayRowAttention?
    private let onDelete: (() -> Void)?
    package init(
      alarm: OneAlarm, date: Date, open: @escaping @MainActor (OneAlarm) -> Void,
      attention: TodayRowAttention? = nil, onDelete: (() -> Void)? = nil, stoppedAt: Date? = nil
    ) {
      self.open = open
      self.alarm = alarm
      self.date = date
      self.stoppedAt = stoppedAt
      self.attention = attention
      self.onDelete = onDelete
    }
    package let alarm: OneAlarm
    package let date: Date
    /// On a past day: when this ring was stopped (recorded by the alarm's Stop). It then shows done: a green check, dimmed.
    package let stoppedAt: Date?

    package var body: some View {
      Button {
        if !alarm.isDeleted { open(alarm) }
      } label: {
        HStack(
          alignment: attention == nil ? .center : .firstTextBaseline,
          spacing: attention == nil ? 10 : 0
        ) {
          TimeColumn(date: date, compact: attention != nil).dynamicTypeSize(
            ...(attention == nil ? DynamicTypeSize.accessibility5 : .xxxLarge))
          Image(systemName: stoppedAt == nil ? "alarm" : "checkmark.circle.fill")
            .font(attention == nil ? .body : AgendaRowStyle.title)
            .foregroundStyle(stoppedAt == nil ? Color.accentColor : Color.green)
            .frame(width: attention == nil && stoppedAt == nil ? 4 + 6 : nil)
            .modifier(AgendaIconSlot(enabled: attention != nil))
          if let stoppedAt {
            TitleDetail(title: Text(alarm.label.isEmpty ? "Alarm" : alarm.label)) {
              Text("Stopped " + stoppedLabel(stoppedAt)).font(.caption)
            }
            .foregroundStyle(.secondary)
          } else {
            Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
              .lineLimit(2)
              .foregroundStyle(alarm.isOn ? Color.primary : Color.secondary)
          }
          Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .font(attention == nil ? Font.body : AgendaRowStyle.title)
        .modifier(TodayItemSurface(enabled: attention != nil))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contextMenu {
        AskAIMenuButton(AskSubject(alarm: alarm))
        Button("Edit Alarm", systemImage: "pencil") { open(alarm) }
        if let attention { Section { attention.menu } }
        Section {
          Button("Delete Alarm", systemImage: "trash", role: .destructive) { deleteAlarm() }
        }
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: attention == nil) {
        if let attention {
          attention.swipeButtons(delete: deleteAlarm).labelStyle(.titleAndIcon)
        } else {
          Button("Delete", systemImage: "trash", role: .destructive) { deleteAlarm() }
          Button("Edit", systemImage: "pencil") { open(alarm) }.tint(.orange)
        }
      }
      .accessibilityIdentifier("today.alarm.row")
      .accessibilityHint("Opens the alarm editor")
      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: attention == nil ? 1 : 0, leading: attention == nil ? 20 : 12,
          bottom: attention == nil ? 1 : 0, trailing: attention == nil ? 20 : 12)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Alarm \(alarm.label) at \(date.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime))"
          + (stoppedAt.map { ", stopped " + stoppedLabel($0) } ?? "")
      )
    }

    private func stoppedLabel(_ date: Date) -> String {
      date.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
    }

    private func deleteAlarm() {
      if let onDelete { onDelete() } else { actions.delete(alarm, context: context, toast: toast) }
    }
  }
#endif

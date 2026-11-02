#if os(iOS)
  import One
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import os
  import SwiftUI
  import SwiftData
  import EventKit

  /// The same gestures on a calendar entry as on a task: swipe from the right for Delete (a full swipe deletes), and
  /// press and hold for the menu (Ask AI, Show Details, Edit, Delete). Tasks keep their own extras (Flag, Today, Tomorrow).
  /// A repeating event asks first whether Delete means this one or the series, so a swipe never silently removes a series.
  /// The question is asked by `entryDeleteDialog` on the container (the list), not on the row: a row is rebuilt when its
  /// swipe actions close, which would drop the dialog.
  package struct EntryActions: ViewModifier {
    @Environment(PlannerActions.self) private var actions
    package let calendar: any CalendarService
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?

    package let entry: CalEntry
    /// Set when Delete needs the "this event or the series" question; the container shows it.
    @Binding package var pendingDelete: CalEntry?
    package var open: (CalEntry) -> Void
    package var edit: (CalEntry) -> Void
    /// Rows in a list get the swipe; blocks on the 2 Day grid only get the long-press menu.
    package var swipes = true
    package var attention: TodayRowAttention? = nil

    /// Whether Delete needs a question first: any repeating event, local or in Apple's calendar.
    private var isRepeating: Bool {
      switch entry.source {
      case .system: entry.repeats
      case .local(let e): e.repeats != nil
      case .task, .alarm: false
      }
    }

    package func body(content: Content) -> some View {
      content
        .contextMenu { menu }
        .modifier(
          SwipeIfRows(
            enabled: swipes, entry: entry, isRepeating: isRepeating, delete: requestDelete,
            flag: toggleFlag, attention: attention, canDelete: canDelete))
    }

    @ViewBuilder private var menu: some View {
      AskAIMenuButton(AskSubject(entry: entry))
      Button {
        open(entry)
      } label: {
        Label("Show Details", systemImage: "info.circle")
      }
      if case .task(let task) = entry.source {
        Button {
          withAnimation { task.flagged.toggle() }
        } label: {
          Label(
            task.flagged ? "Remove Flag" : "Flag", systemImage: task.flagged ? "flag.slash" : "flag"
          )
        }
        Button {
          _ = withAnimation {
            actions.setDue(
              task,
              to: plannerMove(
                task, tomorrow: false, now: presentation.now, calendar: presentation.calendar),
              context: context)
          }
        } label: {
          Label("Today", systemImage: "calendar")
        }
        Button {
          _ = withAnimation {
            actions.setDue(
              task,
              to: plannerMove(
                task, tomorrow: true, now: presentation.now, calendar: presentation.calendar),
              context: context)
          }
        } label: {
          Label("Tomorrow", systemImage: "sunrise")
        }
        Button {
          _ = withAnimation { actions.setDue(task, to: nil, context: context) }
        } label: {
          Label("Unschedule", systemImage: "calendar.badge.minus")
        }
      } else {
        Button {
          edit(entry)
        } label: {
          Label("Edit", systemImage: "pencil")
        }
      }
      if let attention { Section { attention.menu } }
      if attention == nil || canDelete {
        Section {
          Button(role: .destructive) {
            requestDelete()
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
    }

    private func toggleFlag() {
      if case .task(let task) = entry.source { withAnimation { task.flagged.toggle() } }
    }

    private var canDelete: Bool {
      guard attention?.canDelete != false else { return false }
      switch entry.source {
      case .system(let id): return calendar.cachedCanDelete(externalID: id)
      case .local(let event):
        return event.externalID == nil || calendar.cachedCanDelete(externalID: event.externalID)
      case .task, .alarm: return true
      }
    }

    private func requestDelete() {
      if isRepeating {
        pendingDelete = entry
      } else {
        actions.delete(entry, span: .futureEvents, context: context, toast: toast)
      }
    }
  }

  /// Asks "this event or the series?" for the entry in `pending`. Put it on the list or grid that holds the rows.
  package struct EntryDeleteDialog: ViewModifier {
    @Environment(PlannerActions.self) private var actions
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?
    @Binding package var pending: CalEntry?

    package func body(content: Content) -> some View {
      content.confirmationDialog(
        "Delete Event",
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        titleVisibility: .visible,
        presenting: pending
      ) { entry in
        if !entry.repeats {
          Button("Delete Event", role: .destructive) { run(entry, .thisEvent) }
        } else if case .system = entry.source {
          Button("Delete This Event Only", role: .destructive) { run(entry, .thisEvent) }
          Button("Delete All Future Events", role: .destructive) { run(entry, .futureEvents) }
        } else if case .local(let event) = entry.source, event.externalID != nil {
          Button("Delete All Future Events", role: .destructive) { run(entry, .futureEvents) }
        } else {
          Button("Delete All Occurrences", role: .destructive) { run(entry, .futureEvents) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { entry in
        Text(
          entry.repeats
            ? "“\(entry.title)” repeats." : "Delete “\(entry.title)”? This changes its source.")
      }
    }

    private func run(_ entry: CalEntry, _ span: EKSpan) {
      actions.delete(entry, span: span, context: context, toast: toast)
      pending = nil
    }
  }

  /// Swipe from the right: Delete (and Flag on a task). A repeating event never full-swipes, so the question can't be skipped.
  private struct SwipeIfRows: ViewModifier {
    let enabled: Bool
    let entry: CalEntry
    let isRepeating: Bool
    let delete: () -> Void
    let flag: () -> Void
    let attention: TodayRowAttention?
    let canDelete: Bool

    func body(content: Content) -> some View {
      if enabled {
        content.swipeActions(edge: .trailing, allowsFullSwipe: attention == nil && !isRepeating) {
          if let attention {
            var commands: TodayRowAttention {
              var value = attention
              value.canDelete = canDelete
              return value
            }
            commands.swipeButtons(delete: delete).labelStyle(.titleAndIcon)
          } else {
            // Keep the row until the adapter confirms the write, including permission or network failures.
            RowAction.delete(asksFirst: true, delete)
            if case .task(let task) = entry.source { RowAction.flag(task.flagged, flag) }
          }
        }
      } else {
        content
      }
    }
  }

  extension View {
    /// Swipe and long-press actions on a calendar entry (see `EntryActions`).
    package func entryActions(
      _ entry: CalEntry, pendingDelete: Binding<CalEntry?>, open: @escaping (CalEntry) -> Void,
      edit: @escaping (CalEntry) -> Void, swipes: Bool = true, calendar: any CalendarService,
      attention: TodayRowAttention? = nil
    ) -> some View {
      modifier(
        EntryActions(
          calendar: calendar, entry: entry, pendingDelete: pendingDelete, open: open, edit: edit,
          swipes: swipes, attention: attention))
    }

    /// The "this event or the series?" question for a repeating event's Delete (see `EntryActions`).
    package func entryDeleteDialog(_ pending: Binding<CalEntry?>) -> some View {
      modifier(EntryDeleteDialog(pending: pending))
    }
  }
#endif

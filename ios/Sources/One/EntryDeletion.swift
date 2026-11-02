#if os(iOS)
  import TodayCore
  import TodayData
  import SwiftUI
  import SwiftData
  import EventKit

  /// Deleting an entry: an Apple Calendar event, a mirrored local event, or a planned task (which has Undo).
  @MainActor
  package enum EntryDeletion {
    package static func perform(
      _ entry: CalEntry, span: EKSpan, context: ModelContext, toast: UndoToast?,
      calendar: any CalendarService, reminders: any ReminderService,
      alarms: any AlarmService, ledger: Ledger, runtime: PlannerRuntime
    ) {
      switch entry.source {
      case .system(let id):
        let resolution = calendar.focusIdentity(externalID: id, occurrence: entry.start)
        if case .notFound = resolution {
          calendar.refresh()
          toast?.showNotice("This event was already deleted outside Today.")
          return
        }
        guard case .available = resolution else {
          toast?.showNotice(
            "Calendar access is unavailable. This event was kept; reconnect and retry.")
          return
        }
        guard calendar.canDelete(externalID: id) else {
          toast?.showNotice(
            "“\(entry.title)” is in a read-only calendar, so it can't be deleted here.")
          return
        }
        // Activity's Undo only for a one-off with nobody else on it (see `EventUndo.canRestore`).
        let restorable = EventUndo.canRestore(
          repeats: entry.repeats, inAppleCalendar: true,
          attendees: calendar.audience(externalID: id)?.attendees)
        guard calendar.delete(externalID: id, occurrence: entry.start, span: span) else {
          calendar.refresh()
          toast?.showNotice(
            "Couldn't delete “\(entry.title)”. Try again, or delete it in Calendar.")
          return
        }
        calendar.refresh()
        // Start and end let a past day still show an event that was deleted after it happened (`DayHistory`).
        let logged = ledger.record(
          .deleted, kind: "event", title: entry.title,
          before: plannerDayLabel(entry.start, runtime: runtime),
          beforeDate: entry.start, afterDate: entry.end,
          snapshot: restorable
            ? EventSnapshot(
              title: entry.title, start: entry.start,
              durationMinutes: max(1, Int(entry.end.timeIntervalSince(entry.start) / 60)),
              isAllDay: entry.isAllDay, calendarName: entry.calendarTitle, externalID: id)
            : nil,
          context: context)
        // Undo puts back a plain copy (title, time, place) in the default calendar, for a one-off event only:
        // a series has its own rules and attendees that a plain copy would not carry, and it was asked about first.
        guard !entry.repeats else {
          toast?.showNotice("Deleted “\(entry.title)”")
          return
        }
        let backup = OneEvent(
          title: entry.title, start: entry.start,
          durationMinutes: max(1, Int(entry.end.timeIntervalSince(entry.start) / 60)),
          calendarName: entry.calendarTitle)
        backup.isAllDay = entry.isAllDay
        toast?.show("Deleted “\(entry.title)”. Undo adds a new copy in the default calendar.") {
          // Activity's Undo may have put it back already.
          guard !ledger.isUndone(logged) else { return }
          guard case .notFound = calendar.focusIdentity(externalID: id, occurrence: entry.start)
          else {
            toast?.showNotice("Calendar changed again. The event was not recreated.")
            return
          }
          guard calendar.save(backup) != nil else {
            toast?.showNotice("Couldn’t restore this event in Calendar. Try adding it again.")
            return
          }
          calendar.refresh()
          ledger.recordUndo(of: logged, context: context)
        }
      case .local(let event):
        // A local repeating model has no per-occurrence exception storage. Keep the existing series-only
        // action rather than deleting its entire mirror after a single-occurrence source write.
        guard span != .thisEvent || event.repeats == nil else {
          toast?.showNotice(
            "Open this event in Calendar to delete one occurrence. The series was kept.")
          return
        }
        let backup = event.copy()
        let wasLinked = event.externalID != nil
        let externalID = event.externalID
        let resolution = calendar.focusIdentity(externalID: externalID, occurrence: entry.start)
        let alreadyAbsent: Bool
        if case .notFound = resolution { alreadyAbsent = true } else { alreadyAbsent = false }
        let restorable =
          !alreadyAbsent
          && EventUndo.canRestore(
            repeats: event.repeats != nil, inAppleCalendar: wasLinked,
            attendees: wasLinked ? calendar.audience(externalID: externalID)?.attendees : 0)
        if wasLinked {
          switch resolution {
          case .available, .notFound: break
          default:
            toast?.showNotice(
              "Calendar access is unavailable. This event was kept; reconnect and retry.")
            return
          }
        }
        // The copy in Apple Calendar goes first; if it refuses, nothing is deleted anywhere.
        guard
          !wasLinked || calendar.delete(externalID: externalID, occurrence: entry.start, span: span)
        else {
          toast?.showNotice("Couldn't delete “\(event.title)” from Calendar, so it was kept.")
          return
        }
        withAnimation(.snappy) { context.delete(event) }
        do { try context.save() } catch {
          context.insert(event)
          toast?.showNotice(
            wasLinked
              ? "Calendar accepted the deletion, but Today couldn't save its copy. Refresh to retry."
              : "Couldn't save the deletion. This event was kept.")
          return
        }
        let logged = ledger.record(
          .deleted, kind: "event", title: backup.title,
          before: plannerDayLabel(entry.start, runtime: runtime),
          beforeDate: entry.start, afterDate: entry.end,
          snapshot: restorable
            ? EventSnapshot(
              title: backup.title, start: backup.start, durationMinutes: backup.durationMinutes,
              isAllDay: backup.isAllDay, calendarName: backup.calendarName, note: backup.note,
              externalID: externalID, local: true, location: backup.location, url: backup.url,
              busy: backup.busy)
            : nil,
          context: context)
        guard !alreadyAbsent else {
          toast?.showNotice("Removed the local copy. It was already deleted in Calendar.")
          return
        }
        guard !wasLinked || !entry.repeats else {
          toast?.showNotice("Deleted “\(backup.title)”")
          return
        }
        let message =
          wasLinked
          ? "Deleted “\(backup.title)”. Undo adds a new copy in the default calendar."
          : "Deleted “\(backup.title)”"
        toast?.show(message) {
          guard !ledger.isUndone(logged) else { return }
          if wasLinked {
            guard
              case .notFound = calendar.focusIdentity(
                externalID: externalID, occurrence: entry.start)
            else {
              toast?.showNotice("Calendar changed again. The event was not recreated.")
              return
            }
            guard let id = calendar.save(backup) else {
              toast?.showNotice("Couldn’t restore this event in Calendar. Try adding it again.")
              return
            }
            backup.externalID = id
          }
          withAnimation(.snappy) { context.insert(backup) }
          try? context.save()
          ledger.recordUndo(of: logged, item: backup, context: context)
        }
      case .task(let task):
        do {
          try TaskActions.deleteConfirmed(
            task, context: context, toast: toast, reminders: reminders, ledger: ledger,
            runtime: runtime)
        } catch {
          toast?.showNotice("Couldn't delete this reminder. " + error.localizedDescription)
        }
      case .alarm(let alarm):
        AlarmActions.delete(
          alarm, context: context, toast: toast, alarms: alarms, ledger: ledger, runtime: runtime)
      }
    }

    /// Undo from Activity of an event delete: adds the event again from its snapshot, as a new event (Apple Calendar gives
    /// it a new identifier), and only while the deleted one is still gone. Returns nil when done, else why it could not.
    package static func undo(
      _ entry: LedgerItem, context: ModelContext, calendar: any CalendarService, ledger: Ledger
    ) -> String? {
      guard entry.itemKind == "event", entry.actionValue == .deleted,
        let s = ledger.undoSnapshot(EventSnapshot.self, of: entry, context: context)
      else { return ActivityUndoMessage.changedSince }
      if let id = s.externalID {
        switch calendar.focusIdentity(externalID: id, occurrence: s.start) {
        case .notFound: break
        case .available, .localOnly: return ActivityUndoMessage.changedSince
        case .unavailable, .permissionDenied:
          return "Calendar access is unavailable. Reconnect and try again."
        }
      }
      let event = OneEvent(
        title: s.title, start: s.start, durationMinutes: s.durationMinutes,
        calendarName: s.calendarName)
      event.isAllDay = s.isAllDay
      event.note = s.note
      event.location = s.location
      event.url = s.url
      event.busy = s.busy
      if s.externalID != nil {
        guard let id = calendar.save(event) else {
          return "Couldn’t restore this event in Calendar. Try again."
        }
        event.externalID = id
      }
      if s.local {
        context.insert(event)
        try? context.save()
      }
      calendar.refresh()
      ledger.recordUndo(of: entry, item: s.local ? event : nil, context: context)
      ledger.flush(context)
      return nil
    }
  }
#endif

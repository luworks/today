#if os(iOS)
  import One
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Change cards: an edit of the attached item, a saved reminder's repeat, and new-item previews.
  extension AskView {
    /// Resolve an explicit anaphoric edit against the selected identity, never a matching title.
    func routeAttachedEdit(_ text: String) -> Bool {
      guard let subject else { return false }
      let attached = CaptureUndo.resolve(subject.itemRef, in: context)
      let type = subject.kind == .reminder ? "task" : subject.kind.rawValue
      var start = subject.start
      if case .alarm(let alarm)? = attached {
        start = runtime.calendar.nextDate(
          after: now(), matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
          matchingPolicy: .nextTime)
      }
      let candidate = EditItem(
        id: "attached", type: type, title: subject.title,
        start: start, minutes: subject.minutes, attendees: 0)
      guard
        let edit = FastLane.attachedEdit(
          text, attachedItemID: "attached", items: [candidate], now: now(),
          calendar: runtime.calendar)
      else { return false }
      clearPreviews()
      if subject.kind == .event && subject.isSystemEvent == true {
        guard case .move(let start)? = edit.operation,
          let identifier = subject.itemRef, let occurrence = subject.start
        else {
          messages.append(reply("Please open this calendar event to make that change."))
          openSystemEvent = subject.itemRef != nil && subject.start != nil
          return true
        }
        do {
          let snapshot = try calendarSync.moveSnapshot(
            externalID: identifier, occurrence: occurrence)
          let audience = snapshot.audience
          var notes = ["Only this occurrence changes."]
          if audience.attendeeCount == 0 {
            notes.append("No attendees are listed.")
          } else {
            let role =
              audience.isOrganizer == true ? "You are the organizer." : "You are not the organizer."
            notes.append(
              "\(audience.attendeeCount) attendee(s) listed. \(role) Calendar may send updates; Undo may send another update."
            )
          }
          if snapshot.isAllDay { notes.append("The timed event will last 1 hour.") }
          var card = PendingChange(
            subject: .systemEvent, delete: false, title: snapshot.title,
            oldText: subject.whenLabel(calendar: runtime.calendar), newStart: start,
            notes: notes, attendees: audience.attendeeCount)
          card.systemMove = snapshot
          change = card
          messages.append(reply("Here's the change. Nothing changes until you apply it."))
          recordCard(shown: "change", items: 1)
        } catch {
          messages.append(reply("This event can't safely be changed here. Open it in Calendar."))
          openSystemEvent = true
        }
        return true
      }
      guard let operation = edit.operation else {
        messages.append(
          reply(
            edit.reason == "no new time"
              ? "When should I move this item?"
              : "I can't safely prepare that change. Please open the item to edit it."))
        return true
      }
      switch attached {
      case .task(let task):
        var card = PendingChange(
          subject: .task(task), delete: operation == .delete,
          title: task.title,
          oldText: task.due.map { plannerDayLabel($0, runtime: runtime) } ?? "No date",
          newStart: {
            if case .move(let date) = operation { return date }
            return nil
          }(),
          notes: ["Nothing changes until you tap Apply."], attendees: 0)
        card.expectedTask = Ledger.snapshot(of: task)
        card.attachedOperation = operation
        change = card
      case .alarm(let alarm):
        let alarmEdit: AttachedAlarmChange.Edit
        switch operation {
        case .move(let date): alarmEdit = .move(date)
        case .rename(let name): alarmEdit = .rename(name)
        case .delete: alarmEdit = .delete
        default:
          messages.append(
            reply("This alarm change can't be prepared here yet. Open the alarm to edit it."))
          return true
        }
        do {
          var card = PendingChange(
            subject: .alarm(alarm), delete: operation == .delete, title: subject.title,
            oldText: subject.whenLabel(calendar: runtime.calendar),
            newStart: {
              if case .move(let date) = operation { return date }
              return nil
            }(),
            notes: ["Nothing changes until you tap Apply."], attendees: 0)
          card.alarmChange = try AttachedAlarmChange(alarm: alarm, edit: alarmEdit)
          card.attachedOperation = operation
          change = card
        } catch {
          messages.append(reply(error.localizedDescription))
          return true
        }
      case .event(let event):
        switch operation {
        case .move(let date):
          presentEventChange(event, delete: false, newStart: date)
          return true
        case .delete:
          presentEventChange(event, delete: true, newStart: nil)
          return true
        default:
          messages.append(
            reply("This event change can't be prepared in chat. Open the event to edit it."))
          return true
        }
      case nil:
        messages.append(reply("This item is no longer available. Open it to edit it."))
        return true
      }
      messages.append(reply("Here's the change. Nothing changes until you apply it."))
      recordCard(shown: "change", items: 1)
      return true
    }

    // MARK: Editing existing items

    /// Open tasks and the next week's events: what the rules check before reading a message as a new item.
    func editItems() -> [EditItem] {
      EditCandidates.build(
        events: events, tasks: tasks, calendarSync: calendarSync, now: now(),
        calendar: runtime.calendar
      ).items
    }

    /// A move or delete of the event the chat is attached to (Today's own copy), with who it reaches.
    func presentEventChange(_ event: OneEvent, delete: Bool, newStart: Date?) {
      guard event.repeatRule == nil else {
        messages.append(
          reply(
            "“\(event.title)” repeats. Changing a single occurrence isn't supported yet. Open the event to edit it."
          ))
        return
      }
      let audience = calendarSync.audience(externalID: event.externalID)
      var notes: [String] = []
      if let a = audience, a.attendees > 0 {
        notes.append(
          a.isOrganizer
            ? "The invitation update goes to \(a.attendees) attendee\(a.attendees == 1 ? "" : "s")."
            : "You're not the organizer: this changes your own calendar only; \(a.attendees) attendee\(a.attendees == 1 ? "" : "s") won't be told."
        )
      } else {
        notes.append("Only on your calendar. No one else is notified.")
      }
      notes.append("Meetings move only when you ask. This changes this one event.")
      change = PendingChange(
        subject: .event(event), delete: delete, title: event.title,
        oldText: plannerDayLabel(event.start, runtime: runtime), newStart: newStart,
        notes: notes, attendees: audience?.attendees ?? 0)
      messages.append(reply("Here's the change. Nothing changes until you apply it."))
      recordCard(shown: "change", items: 1)
    }

    func apply(_ c: PendingChange) {
      if case .systemEvent = c.subject, let snapshot = c.systemMove, let start = c.newStart {
        let result = AskNativeActions.applySystemMove(
          snapshot, to: start, context: context, calendar: calendarSync, ledger: ledger,
          runtime: runtime, report: { messages.append($0) })
        if result.feedback.applied {
          recordCard(resolved: "change", "applied")
          change = nil
        }
        if let after = result.moved {
          subject?.itemRef = after.externalID
          subject?.start = after.start
          subject?.isAllDay = false
          subject?.minutes = Int(after.end.timeIntervalSince(after.start) / 60)
          thread?.subject = subject
          try? context.save()
        }
        show(result.feedback, card: "change")
        return
      }
      if case .task(let task) = c.subject, let operation = c.attachedOperation,
        let expected = c.expectedTask
      {
        do {
          let receipt = try actions.applyAttachedReminder(
            operation, task: task, expected: expected, context: context)
          recordCard(resolved: "change", "applied")
          change = nil
          messages.append(reply("The reminder was updated."))
          offerUndo("Changed the reminder.", card: "change") {
            do { try receipt.undo() } catch { messages.append(reply(error.localizedDescription)) }
          }
        } catch { messages.append(reply(error.localizedDescription)) }
        return
      }
      if case .alarm = c.subject, let proposal = c.alarmChange {
        Task { @MainActor in
          do {
            let entry = try await actions.applyAttachedAlarm(proposal, context: context)
            recordCard(resolved: "change", "applied")
            change = nil
            messages.append(reply("The alarm was updated."))
            offerUndo("Changed the alarm.", card: "change") {
              Task { @MainActor in
                if let error = await actions.undo(entry, context: context) {
                  messages.append(reply(error))
                }
              }
            }
          } catch { messages.append(reply(error.localizedDescription)) }
        }
        return
      }
      let feedback = AskNativeActions.applyChange(
        c, context: context, calendar: calendarSync, actions: actions, ledger: ledger,
        runtime: runtime)
      if feedback.applied {
        recordCard(resolved: "change", "applied")
        change = nil
      }
      show(feedback, card: "change")
    }

    func show(_ feedback: AskActionFeedback, card: String) {
      messages.append(contentsOf: feedback.messages)
      if let undo = feedback.undo { offerUndo(undo.label, card: card, undo.action) }
    }

    /// The app's toast sits behind this full-screen page, so Undo lives here.
    func offerUndo(_ label: String, card: String, _ action: @escaping () -> Void) {
      undoRow = UndoRow(
        label: label,
        action: {
          activity.record(ActivityEvents.aiUndo(card: card, thread: threadID))
          withAnimation(reduceMotion ? nil : .default) { action() }
        })
    }

    /// The Send tap is the scoped approval for a clear one-off reminder. Save errors leave
    /// the same card open; Added/Undo/Open come only from the normal commit receipt.
    func createSubmittedReminder(_ capture: Capture) {
      let message = reply("Saving reminder…")
      var proposal = CaptureProposal(capture: filed(capture), anchor: message.id)
      proposal.retainsDraft = true
      proposals.append(proposal)
      recordCard(shown: "capture", items: 1)
      messages.append(message)
      // Direct creation can precede SwiftUI's message-persistence callback on a new chat.
      // Establish the thread first so its item relationship receives the real save receipt.
      persist()
      let saved = commit(proposal.id) != nil
      if let index = messages.firstIndex(where: { $0.id == message.id }) {
        messages[index] = ChatMessage(
          id: message.id, role: .ai,
          text: saved ? "Added." : "Reminder not added. Your draft is ready to retry or cancel.",
          timestamp: message.timestamp)
      }
      persist()
      persistCards()
    }

    func show(_ captures: [Capture], note: String? = nil) {
      guard !captures.isEmpty else {
        messages.append(
          reply("I couldn't prepare an item from that. Tell me what you'd like to add."))
        return
      }
      let message = reply(
        note
          ?? (captures.count == 1
            ? "Here's what I understood. Nothing is added until you confirm."
            : "I found \(captures.count) items. Add them one by one or all at once; nothing is added until you confirm.")
      )
      let batch = UUID()
      // Earlier cards stay where they are; the new ones sit under the message that proposes them.
      dropOpenCards()
      proposals += captures.map {
        CaptureProposal(
          capture: filed($0), batchSize: captures.count, batch: batch, anchor: message.id)
      }
      recordCard(shown: "capture", items: captures.count)
      messages.append(message)
    }

    /// A task goes to the list it clearly belongs to, else the list chosen in Settings > Reminders ("New reminders go to"),
    /// else the Inbox. Never silently to whatever list is the default.
    func filed(_ capture: Capture) -> Capture {
      guard capture.kind == .task, !capture.ringsAsAlarm, capture.listName == nil else {
        return capture
      }
      var c = capture
      let names = lists.map(\.name)
      let candidates = lists.map { list in
        ListGuess.Candidate(
          name: list.name,
          titles: tasks.filter { $0.listName == list.name }.suffix(300).map(\.title))
      }
      c.listName =
        ListGuess.guess(c.title, lists: candidates).list ?? Preferences.newReminderList(
          existing: names, presentation.defaults) ?? ListGuess.inbox(in: names)
      return c
    }
  }
#endif

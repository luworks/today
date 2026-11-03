#if os(iOS)
  import One
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Activity data for each turn and card, and the capture cards' Add, Cancel, Undo and Open.
  extension AskView {
    // MARK: Activity data (tier 2)

    /// The routing of one message: where it went, and how long and in what language it was. The text itself is not copied
    /// unless the user switched that on (Settings → Activity data).
    func recordTurn(_ intent: String, _ text: String, route: String = "rules") {
      // This describes the initial routing decision, before any model response or extraction.
      activity.record(
        ActivityEvents.aiTurn(
          intent: intent, route: route, text: text,
          keepText: activity.settings.keepChatText, thread: threadID))
    }

    func recordCard(shown card: String, items: Int) {
      cardShownAt = now()
      activity.record(
        ActivityEvents.cardShown(
          card: card, items: items,
          latencyMs: Int(now().timeIntervalSince(turnStart) * 1000), thread: threadID))
    }

    func recordCard(
      resolved card: String, _ outcome: String, items: Int = 1, edits: [ActivityContent] = []
    ) {
      let dwell = cardShownAt.map { Int(now().timeIntervalSince($0) * 1000) }
      activity.record(
        ActivityEvents.cardResolved(
          card: card, outcome: outcome, edits: edits, items: items, dwellMs: dwell, thread: threadID
        ))
    }

    /// Cards still waiting for a tap when they go away (a new message, the screen closing) are recorded as ignored.
    func closeOpenCards(_ outcome: String) {
      if !tidy.isEmpty { recordCard(resolved: "tidy", outcome, items: tidy.count) }
      let open = proposals.filter { $0.status == .open }.count
      if open > 0 { recordCard(resolved: "capture", outcome, items: open) }
      if change != nil { recordCard(resolved: "change", outcome) }
    }

    func dropOpenCards() {
      for i in proposals.indices where !proposals[i].retainsDraft {
        if let next = proposals[i].status.after(.drop) {
          proposals[i].status = next
          if let id = proposals[i].agentID { agent?.tools.mark(id, .dropped) }
        }
      }
    }

    // MARK: Cards: Add, Cancel, Undo, Open

    /// The cards under one AI message, grouped by line (a line's items are one card or one list).
    @ViewBuilder
    func cards(under anchor: UUID) -> some View {
      let batches = proposals.filter { $0.anchor == anchor }.map(\.batch).reduce(into: [UUID]()) {
        if !$0.contains($1) { $0.append($1) }
      }
      ForEach(batches, id: \.self) { batch in
        CaptureStack(
          proposals: batchBinding(batch), lists: lists.map(\.name),
          onAdd: add, onSkip: skip, onAddAll: addAll, onUndo: undo, onOpen: open, onRename: rename,
          calendars: calendarSync.calendars().filter(\.allowsContentModifications).map {
            EventCalendarOption(id: $0.id, title: $0.title, color: $0.color)
          },
          onEventOptions: eventOptions
        )
        .id(batch)
      }
    }

    func batchBinding(_ batch: UUID) -> Binding<[CaptureProposal]> {
      Binding(
        get: { proposals.filter { $0.batch == batch } },
        set: { new in
          for p in new {
            if let i = proposals.firstIndex(where: { $0.id == p.id }),
              proposals[i].pendingExternalID == nil
            {
              proposals[i] = p
            }
          }
        })
    }

    /// Saves the decided cards with the conversation (the open ones are not kept).
    func persistCards() {
      guard let thread else { return }
      let decided = proposals.compactMap(\.stored).filter { $0.status != .open || $0.retainsDraft }
      guard thread.cards != decided else { return }
      thread.cards = decided
      thread.updatedAt = now()
      try? context.save()
    }

    func add(_ id: UUID) {
      commit(id)
    }

    func addAll() {
      for p in proposals where p.status == .open { commit(p.id) }
    }

    /// Writes one proposal (a card that was undone can be added again) and marks it Added. The card stays; it remembers
    /// what was written so Undo and Open reach exactly that.
    /// `reportFailure` false: the caller says it in its own receipt.
    @discardableResult
    func commit(_ id: UUID, reportFailure: Bool = true) -> Capture? {
      guard let i = proposals.firstIndex(where: { $0.id == id }),
        let next = proposals[i].status.after(.add)
      else { return nil }
      let capture = proposals[i].capture
      guard capture.isReadyToAdd(calendar: presentation.calendar) else { return nil }
      let edits = CaptureEdits.diff(shown: proposals[i].original, final: capture)
      let written: (id: PersistentIdentifier, entry: LedgerItem)
      do {
        if capture.kind == .event {
          proposals[i].retainsDraft = true
          let result = try actions.insertCalendarEvent(
            capture, requestID: id, recoveryExternalID: proposals[i].pendingExternalID,
            into: context)
          written = (result.id, result.entry)
          if result.localOnly {
            messages.append(reply("Saved in Today only. Apple Calendar is not connected."))
          }
        } else if proposals[i].retainsDraft && FastLane.isEligibleOneOff(capture) {
          written = try actions.insertOneOffReminder(
            capture, requestID: id,
            recoveryExternalID: proposals[i].pendingExternalID, into: context)
        } else {
          guard proposals[i].pendingExternalID == nil else { throw CocoaError(.coderInvalidValue) }
          written = try actions.insert(
            capture, into: context, actor: .todayAI, channel: .ask, approval: .asked)
        }
      } catch {
        proposals[i].pendingExternalID =
          capture.kind == .event
          ? actions.pendingEventCreationID(id) : actions.pendingReminderCreationID(id)
        persistCards()
        if reportFailure {
          messages.append(
            reply(
              "Couldn't save “\(capture.title)”: \(error.localizedDescription) The draft is still here; tap Add to retry."
            ))
        }
        return nil
      }
      recordCard(resolved: "capture", edits.isEmpty ? "applied" : "edited", edits: edits)
      thread?.items.append(written.id)
      onAdded(capture)
      proposals[i].itemRef = Ledger.ref(written.id)
      proposals[i].entryID = written.entry.id
      proposals[i].status = next
      proposals[i].pendingExternalID = nil
      if let aid = proposals[i].agentID {
        agent?.tools.mark(aid, .added, created: proposals[i].itemRef)
        saveAgentHistory()
      }
      return capture
    }

    /// Cancel / Skip: the card stays in the chat, dimmed, as Dropped.
    func skip(_ id: UUID) {
      guard let i = proposals.firstIndex(where: { $0.id == id }),
        let next = proposals[i].status.after(.drop)
      else { return }
      if proposals[i].pendingExternalID != nil {
        do {
          if proposals[i].capture.kind == .event {
            try actions.cancelEventCreation(
              proposals[i].capture, requestID: id,
              recoveryExternalID: proposals[i].pendingExternalID)
          } else {
            try actions.cancelReminderCreation(
              proposals[i].capture, requestID: id,
              recoveryExternalID: proposals[i].pendingExternalID, context: context)
          }
        } catch {
          messages.append(
            reply(
              "Couldn't cancel the system item: \(error.localizedDescription) Retry from this card."
            ))
          return
        }
        proposals[i].pendingExternalID = nil
      }
      if proposals[i].status == .open { recordCard(resolved: "capture", "skipped") }
      proposals[i].status = next
      if let aid = proposals[i].agentID { agent?.tools.mark(aid, .dropped) }
    }

    /// Takes back exactly what Add wrote (the reminder, alarm or event), recorded in Activity. The card shows Undone.
    func undo(_ id: UUID) {
      guard let i = proposals.firstIndex(where: { $0.id == id }),
        let next = proposals[i].status.after(.undo)
      else { return }
      let p = proposals[i]
      guard
        actions.undoCapture(
          itemRef: p.itemRef, entryID: p.entryID, title: p.capture.title, context: context)
      else {
        messages.append(
          reply("Couldn't take “\(p.capture.title)” back from Calendar, so it was kept."))
        return
      }
      if let ref = p.itemRef, let pid = CaptureUndo.decode(ref) {
        thread?.items.removeAll { $0 == pid }
      }
      if p.capture.kind == .event {
        actions.didUndoEventCreation(id)
      } else if p.retainsDraft {
        actions.didUndoReminderCreation(id)
      }
      proposals[i].itemRef = nil
      proposals[i].entryID = nil
      proposals[i].status = next
      if let aid = proposals[i].agentID { agent?.tools.mark(aid, .undone) }
    }

    /// Opens what Add wrote: the reminder or alarm in its editor, an event as its day in Today.
    func open(_ id: UUID) {
      guard let p = proposals.first(where: { $0.id == id }) else { return }
      switch CaptureUndo.resolve(p.itemRef, in: context) {
      case .task(let task): onOpenTask(task, refreshCardTitles)
      case .alarm(let alarm): onOpenAlarm(alarm, refreshCardTitles)
      case .event(let event): onOpenDay(event.start)
      case nil: messages.append(reply("“\(p.capture.title)” isn't there any more."))
      }
    }

    /// Save changes the existing item, then every card in this chat that refers to it.
    func rename(_ id: UUID, to title: String) -> Bool {
      guard let p = proposals.first(where: { $0.id == id }), p.status == .added,
        let old = actions.captureTitle(p.itemRef, in: context)
      else { return false }
      guard old != title else {
        refreshCardTitles()
        return true
      }
      guard actions.renameCapture(p.itemRef, to: title, in: context) else { return false }
      let task: OneTask?
      let kind: String
      switch CaptureUndo.resolve(p.itemRef, in: context) {
      case .task(let t):
        task = t
        kind = "task"
      case .alarm:
        task = nil
        kind = "alarm"
      case .event:
        task = nil
        kind = "event"
      case nil: return false
      }
      let entry = ledger.record(
        .renamed, task: task, kind: kind, title: title,
        before: old, after: title, channel: .ask, context: context)
      refreshCardTitles()
      toast?.show("Changed title") {
        // Do not replace another edit made since this save, or resurrect an item deleted since.
        guard actions.captureTitle(p.itemRef, in: context) == title,
          actions.renameCapture(p.itemRef, to: old, in: context)
        else { return }
        ledger.recordUndo(of: entry, task: task, channel: .ask, context: context)
        refreshCardTitles()
      }
      return true
    }

    /// The calendar / alert menu on an event card. Before Add it only edits the card; after Added it moves the event and
    /// replaces its alert in place, recorded in Activity. Undo and Open keep working on the same event.
    func eventOptions(_ id: UUID, calendarID: String?, alert: Int) -> Bool {
      guard let p = proposals.first(where: { $0.id == id }) else { return false }
      switch p.status {
      case .open: return true
      case .added:
        let minutes = alert == Preferences.noEventAlert ? nil : alert
        guard
          actions.setCaptureEventOptions(
            p.itemRef, calendarID: calendarID, alertMinutes: minutes, in: context)
        else {
          toast?.showNotice("Couldn’t change “\(p.capture.title)” in Calendar.")
          return false
        }
        let name = { (id: String?) in
          calendarSync.calendars().first { $0.id == id }?.title ?? "Calendar"
        }
        ledger.record(
          .edited, kind: "event", title: p.capture.title,
          before: name(p.capture.calendarID) + " · "
            + Preferences.newEventAlertLabel(p.capture.alertMinutes ?? Preferences.newEventAlert),
          after: name(calendarID) + " · " + Preferences.newEventAlertLabel(alert),
          channel: .ask, context: context)
        DispatchQueue.main.async { persistCards() }
        return true
      default: return false
      }
    }

    func refreshCardTitles() {
      for i in proposals.indices where proposals[i].status == .added {
        if let title = actions.captureTitle(proposals[i].itemRef, in: context) {
          proposals[i].capture.title = title
        }
      }
      persistCards()
    }

    func isOverdue(_ task: OneTask) -> Bool {
      !task.isDone && (task.due.map { $0 < runtime.calendar.startOfDay(for: now()) } ?? false)
    }

    /// Tidy overdue (offline rules): a new date for every overdue reminder (see `OverdueTidy`), applied
    /// at once with Undo (owner decision 2026-11-02).
    func tidyOverdue() {
      let overdue = tasks.filter { isOverdue($0) }
      guard !overdue.isEmpty else {
        messages.append(reply("Nothing is overdue."))
        return
      }
      let items = overdue.enumerated().compactMap { i, t in
        t.due.map {
          OverdueTidy.Item(id: i, due: $0, flagged: t.flagged, repeats: t.repeats != nil)
        }
      }
      tidy = OverdueTidy.suggest(items, now: now(), calendar: runtime.calendar).compactMap { s in
        overdue[s.id].due.map { TidyRow(task: overdue[s.id], oldDue: $0, choice: s.choice) }
      }
      recordCard(shown: "tidy", items: tidy.count)
      messages.append(
        reply(
          "Flagged and recent ones first, three a day; ones older than a month lose their date but stay in their list."
        ))
      applyTidy()
    }

    /// Writes the Tidy rows with an Undo row; says what it did.
    func applyTidy() {
      let count = tidy.filter { $0.choice != .keep }.count
      let feedback = AskNativeActions.applyTidy(
        rows: &tidy, context: context, actions: actions, ledger: ledger, runtime: runtime)
      if feedback.applied {
        recordCard(resolved: "tidy", "applied", items: count)
        if let id = agentTidyID { agent?.tools.mark(id, .applied) }
        agentTidyID = nil
      }
      show(feedback, card: "tidy")
    }

    /// The agent's Tidy card applied right after the reply: the reply's receipt says what changed,
    /// so only the Undo row is shown here. False when the save failed (the rows stay).
    func applyTidyNow() -> Bool {
      let count = tidy.filter { $0.choice != .keep }.count
      let feedback = AskNativeActions.applyTidy(
        rows: &tidy, context: context, actions: actions, ledger: ledger, runtime: runtime)
      guard feedback.applied else { return false }
      recordCard(resolved: "tidy", "applied", items: count)
      if let id = agentTidyID { agent?.tools.mark(id, .applied) }
      agentTidyID = nil
      if let undo = feedback.undo { offerUndo(undo.label, card: "tidy", undo.action) }
      return true
    }
  }
#endif

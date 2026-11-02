#if os(iOS)
  import One
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// The agent side of Ask, and the rules-only path when it can't run (§4.7 #3).
  extension AskView {
    // MARK: Agent (docs/engineering/ai-agent-architecture.md)

    func agentSession() -> AskAgentSession {
      if let agent { return agent }
      let history = AgentHistory.restore(thread?.agentItemsData ?? Data(), now: now())
      let tools = AgentPlannerTools(
        history: history, context: context, calendar: calendarSync, actions: actions,
        ledger: ledger, runtime: runtime)
      let session = AskAgentSession(tools: tools)
      session.onCreate = { card, anchor in
        guard case .create(let capture) = card.body else { return }
        let batch =
          proposals.last(where: { $0.agentID != nil && $0.anchor == anchor })?.batch ?? UUID()
        var proposal = CaptureProposal(capture: filed(capture), batch: batch, anchor: anchor)
        proposal.agentID = card.id
        proposals.append(proposal)
        let n = proposals.filter { $0.batch == batch }.count
        for i in proposals.indices where proposals[i].batch == batch { proposals[i].batchSize = n }
      }
      session.onReviseCreate = { card in
        guard case .create(let capture) = card.body,
          let i = proposals.firstIndex(where: { $0.agentID == card.id }),
          proposals[i].status == .open, proposals[i].pendingExternalID == nil
        else { return }
        proposals[i].capture = filed(capture)
      }
      session.onTidy = { card in
        guard case .tidy(let rows) = card.body else { return }
        tidy = rows.map { TidyRow(task: $0.task, oldDue: $0.expectedDue, choice: $0.choice) }
        agentTidyID = card.id
      }
      agent = session
      return session
    }

    /// Runs the agent on one message. Cards appear as their tool calls complete; the reply comes last.
    /// If the AI can't be reached before any card, the message goes back into the composer.
    func runAgent(typed: String, text: String, anchor: UUID) {
      let session = agentSession()
      let chinese = AgentReply.isChinese(typed)
      let runID = AskAgentSession.runID()
      session.anchor = anchor
      session.tools.turn = AgentTurn(text: text, chinese: chinese, runID: runID)
      if session.tools.history.needsCompaction { compactAgentHistory(session) }
      var attached: String?
      if let subject {
        var line = subject.contextLine(calendar: runtime.calendar)
        if let ref = subject.itemRef, subject.isSystemEvent != true {
          let prefix = subject.kind == .event ? "e" : (subject.kind == .alarm ? "a" : "t")
          line +=
            " (id \(session.tools.history.shortID(for: Ledger.comparisonKey(ref), prefix: prefix)))"
        }
        attached = line
      }
      let message =
        text + "\n\n"
        + AskAgentSession.context(
          now: now(), calendar: runtime.calendar, locale: runtime.locale, chinese: chinese,
          attached: attached)
      recordTurn("agent", text, route: "agent")
      thinking = true
      let history = session.tools.history.items
      captureTask = Task { @MainActor in
        let client = agentModel.client
        var result = await AgentRunner(client: client, toolbox: session.tools).run(
          history: history, message: message, runID: runID, chinese: chinese)
        // A replay OpenAI can't verify (e.g. after a model update): compact to text and retry once.
        if result.failed == .replayRejected, !history.isEmpty, !Task.isCancelled {
          compactAgentHistory(session)
          let remaining = AgentContract.maxSteps - result.steps
          if remaining > 0 {
            result = await AgentRunner(client: client, toolbox: session.tools, maxSteps: remaining)
              .run(
                history: session.tools.history.items, message: message, runID: runID,
                chinese: chinese)
          }
        }
        AskAgentSession.logRun(result, runID: runID)
        guard !Task.isCancelled else { return }
        thinking = false
        session.tools.history.items += result.items
        saveAgentHistory()
        // The AI couldn't be reached before any card: the rules take over (§4.7 #3).
        if let error = result.failed, result.cards == 0 {
          runLocally(text, typed: typed, error: error)
          return
        }
        if result.cards > 0 { recordCard(shown: "agent", items: result.cards) }
        // Clear requests are applied right after the reply, with Undo (owner decision 2026-11-02).
        // What was written is said by code, in the past tense; the model's "tap Add" never shows.
        let receipt = await autoApply(session, anchor: anchor, chinese: chinese)
        var text = result.reply
        if !receipt.added.isEmpty || !receipt.changed.isEmpty || !receipt.failed.isEmpty {
          text = AgentReply.receipt(receipt, chinese: chinese)
          if result.stop != .finished {
            text = AgentReply.stoppedEarly(chinese: chinese) + " " + text
          }
        }
        // The model's own words can be copied; the app's replacement sentences can't.
        let own = !result.modelText.isEmpty && text == result.modelText
        messages.append(
          ChatMessage(role: .ai, text: text, timestamp: now(), carriesContent: own ? true : nil))
        persistCards()
      }
    }

    /// Applies this turn's `direct` cards (owner decision 2026-11-02): new items through the same
    /// commit as Add (Added only after the save succeeded), changes through the code-owned `apply`
    /// with its live re-check, Tidy with its Undo row. Cards that reach other people, change a whole
    /// series, answer a question rather than a request, or lack what they need stay open.
    func autoApply(_ session: AskAgentSession, anchor: UUID, chinese: Bool) async
      -> AgentReply.Receipt
    {
      var receipt = AgentReply.Receipt()
      for p in proposals where p.anchor == anchor && p.status == .open {
        guard let aid = p.agentID, session.tools.cards[aid]?.tier == .direct,
          ActionPolicy.autoAddReady(p.capture)
        else {
          receipt.waiting += 1
          continue
        }
        if let written = commit(p.id, reportFailure: false) {
          receipt.added.append(
            AgentReply.label(kind: written.policyKind, title: written.title, chinese: chinese))
        } else {
          receipt.failed.append(p.capture.title)
        }
      }
      for change in session.changes where change.anchor == anchor && change.status == .open {
        guard session.tools.cards[change.id]?.tier == .direct,
          case .change(let c) = change.card.body
        else {
          receipt.waiting += 1
          continue
        }
        await session.apply(change.id)
        let after = session.changes.first(where: { $0.id == change.id })
        if after?.status == .applied {
          recordCard(resolved: "agent-change", "applied")
          receipt.changed.append(AgentReply.label(kind: c.kind, title: c.title, chinese: chinese))
        } else if after?.status == .open, after?.card.tier != .direct {
          // The stakes went up since the card was made (e.g. attendees): it waits for a tap.
          receipt.waiting += 1
        } else {
          receipt.failed.append(c.title)
        }
      }
      if let id = agentTidyID, !tidy.isEmpty {
        if session.tools.cards[id]?.tier == .direct {
          let n = tidy.filter { $0.choice != .keep }.count
          if applyTidyNow() {
            receipt.changed.append(
              chinese ? "\(n) 条逾期提醒的日期" : "the dates of \(n) overdue reminders")
          } else {
            receipt.failed.append(chinese ? "整理逾期" : "Tidy overdue")
          }
        } else {
          receipt.waiting += 1
        }
      }
      saveAgentHistory()
      return receipt
    }

    /// Offline, signed out, over quota or a failed request (§4.7 #3): FastLane alone. Tidy keeps working,
    /// a reminder, event or alarm the rules are sure of is added with Undo, and anything else says
    /// the AI is unavailable and puts the draft back in the composer.
    func runLocally(_ text: String, typed: String, error: ModelClientError) {
      if OverdueTidy.isRequest(text) {
        recordTurn("tidy", text, route: "offline")
        clearPreviews()
        tidyOverdue()
        return
      }
      let chinese = AgentReply.isChinese(typed)
      if let capture = FastLane.localPreview(
        text, items: editItems(), now: now(), calendar: runtime.calendar)
      {
        recordTurn("capture", text, route: "offline")
        clearPreviews()
        show([capture], lead: AgentReply.localRules(error, chinese: chinese), chinese: chinese)
        return
      }
      recordTurn("unavailable", text, route: "offline")
      messages.append(reply(AgentReply.unavailable(error, chinese: chinese)))
      if draft.isEmpty { draft = typed }
    }

    /// Text plus card receipts in place of replayable items (§1.5): version change, size, or a rejected replay.
    func compactAgentHistory(_ session: AskAgentSession) {
      let transcript = messages.dropLast().map { (isUser: $0.role == .user, text: $0.text) }
      let captures = proposals.filter { $0.agentID == nil && $0.status != .open }.map {
        "card “\($0.capture.title)” \($0.status.rawValue)"
      }
      session.tools.history.compact(
        transcript: Array(transcript), receipts: session.tools.receipts + captures, now: now())
      saveAgentHistory()
    }

    func saveAgentHistory() {
      guard let agent else { return }
      if thread == nil { persist() }
      guard let thread else { return }
      let data = agent.tools.history.encoded
      guard thread.agentItemsData != data else { return }
      thread.agentItemsData = data
      try? context.save()
    }

    /// What FastLane added goes into the agent's history as a receipt with its item id (§1.5),
    /// so a follow-up like "其实是4点" can find it.
    func recordFastLaneReceipt(typed: String) {
      guard let p = proposals.last, p.agentID == nil, p.status == .added, let ref = p.itemRef
      else { return }
      let session = agentSession()
      let kind = p.capture.policyKind
      let prefix = kind == .event ? "e" : (kind == .alarm ? "a" : "t")
      let id = session.tools.history.shortID(for: Ledger.comparisonKey(ref), prefix: prefix)
      let due = p.capture.taskTiming(calendar: runtime.calendar).due
      let when = due.map { plannerDayLabel($0, runtime: runtime) } ?? "no date"
      session.tools.history.appendReceipt(
        user: typed,
        receipt:
          "Receipt from the app (rules, no model): added \(kind.rawValue) \(id) “\(p.capture.title)”, \(when), "
          + "from the user's own words. The user can Undo it on its card.")
      saveAgentHistory()
    }

    @ViewBuilder
    func agentChanges(under anchor: UUID) -> some View {
      if let agent {
        ForEach(agent.changes.filter { $0.anchor == anchor }) { change in
          AgentChangeCardView(
            change: change,
            onApply: {
              Task { @MainActor in
                await agent.apply(change.id)
                if agent.changes.first(where: { $0.id == change.id })?.status == .applied {
                  recordCard(resolved: "agent-change", "applied")
                }
                saveAgentHistory()
              }
            },
            onCancel: {
              agent.cancel(change.id)
              recordCard(resolved: "agent-change", "cancelled")
            },
            onUndo: {
              Task { @MainActor in
                await agent.undo(change.id)
                activity.record(ActivityEvents.aiUndo(card: "agent-change", thread: threadID))
              }
            })
        }
      }
    }
  }
#endif

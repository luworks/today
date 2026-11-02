#if os(iOS)
  import One
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Full-screen AI page, modeled on ChatGPT / Claude mobile. The shell builds it hidden ahead of time and reveals it.
  /// Conversation stays conversational; only requests to add items become capture previews.
  /// Explicit Send approves a clear one-off reminder; other changes keep their Add / Apply gate.
  package struct AskView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dismiss) var dismiss
    let isPresented: Bool
    let onClose: (() -> Void)?
    /// Opens the sidebar (past chats); no menu button when nil.
    let onMenu: (() -> Void)?
    @Environment(\.modelContext) var context
    @Environment(UndoToast.self) var toast: UndoToast?
    @Query(sort: \OneTask.createdAt) var tasks: [OneTask]
    @Query(sort: \OneEvent.start) var events: [OneEvent]

    let calendarSync: any CalendarService
    let actions: PlannerActions
    let ledger: Ledger
    let activity: ActivityCenter
    let agentModel: AgentModel
    let presentation: PlannerPresentation
    var runtime: PlannerRuntime { presentation.runtime }
    let now: () -> Date
    /// The item this chat was opened about (its "Ask AI" menu row); nil for an ordinary chat.
    @State var subject: AskSubject?

    let onAdded: (Capture) -> Void
    /// Asks the presenter to show what this screen goes back to (`true`), underneath it, or to undo that
    /// when a back swipe is cancelled (`false`). Called before the screen closes, by the close button or a swipe.
    let onBack: (Bool) -> Void
    /// "Open" on an added event: closes this screen and shows that day in Today.
    let onOpenDay: (Date) -> Void

    /// The saved conversation this screen continues. nil = a new chat; the thread is created on the first user message.
    @State var thread: ChatThread?
    /// The chat's id from the first message on (the saved thread takes it), so Activity data events can point at it.
    @State var threadID: UUID
    /// When the last message was sent / the last card appeared: latency and dwell time for Activity data.
    @State var turnStart: Date
    @State var cardShownAt: Date?
    @State var messages: [ChatMessage]
    @State var draft = ""
    /// The Reminder / Event / Alarm button the user selected for the next message (`AskQuickKind`).
    @State var quickKind: AskQuickKind?
    @State var followsTail = true
    @State var scrollPhase: ScrollPhase = .idle

    struct ConversationGeometry: Equatable {
      let nearEnd: Bool
      let offset: CGFloat
      let content: CGSize
      let viewport: CGSize
    }

    var isUserScrolling: Bool {
      scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating
    }

    var cardTransition: AnyTransition {
      reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    func followEnd(_ proxy: ScrollViewProxy) {
      guard followsTail else { return }
      withAnimation(reduceMotion ? nil : .default) {
        proxy.scrollTo(Self.endID, anchor: .bottom)
      }
    }
    /// The preview cards of this conversation, each under the AI message that proposed it. They stay after Add / Cancel
    /// (Added, Dropped, Undone) and are saved with the conversation.
    @State var proposals: [CaptureProposal] = []
    /// Shell presents the typed editor above this Ask modal and calls the supplied handler on dismiss.
    let onOpenTask: (OneTask, @escaping () -> Void) -> Void
    let onOpenAlarm: (OneAlarm, @escaping () -> Void) -> Void

    static let endID = "chat-end"
    @Query(sort: \OneList.order) var lists: [OneList]
    @State var thinking = false
    /// The agent side of this conversation; created on its first use.
    @State var agent: AskAgentSession?
    /// The Tidy card the agent prepared, so Apply/Cancel are recorded against its proposal.
    @State var agentTidyID: String?
    @State var captureTask: Task<Void, Never>?
    /// "Tidy overdue": a new date per overdue reminder, waiting for Apply.
    @State var tidy: [TidyRow] = []
    @State var voice: VoiceInput
    @State var change: PendingChange?
    @State var openSystemEvent = false
    @State var undoRow: UndoRow?
    /// What the last turn left open (a "which one?" with real items, or a "when?"), so the next message can answer it.
    @State var followup: Followup?
    @State var focused = false

    package init(
      thread: ChatThread? = nil, subject: AskSubject? = nil, isPresented: Bool = true,
      onClose: (() -> Void)? = nil,
      onMenu: (() -> Void)? = nil, calendar: any CalendarService, now: @escaping () -> Date,
      actions: PlannerActions, ledger: Ledger, activity: ActivityCenter,
      agentModel: AgentModel, voice: VoiceInput,
      presentation: PlannerPresentation,
      onBack: @escaping (Bool) -> Void, onAdded: @escaping (Capture) -> Void,
      onOpenDay: @escaping (Date) -> Void,
      onOpenTask: @escaping (OneTask, @escaping () -> Void) -> Void,
      onOpenAlarm: @escaping (OneAlarm, @escaping () -> Void) -> Void
    ) {
      let attached = thread?.subject ?? subject
      _subject = State(initialValue: attached)
      self.isPresented = isPresented
      self.onClose = onClose
      self.onMenu = onMenu
      self.calendarSync = calendar
      self.now = now
      self.actions = actions
      self.ledger = ledger
      self.activity = activity
      self.agentModel = agentModel
      self.presentation = presentation
      _voice = State(initialValue: voice)
      _turnStart = State(initialValue: now())
      self.onOpenTask = onOpenTask
      self.onOpenAlarm = onOpenAlarm
      self.onAdded = onAdded
      self.onBack = onBack
      self.onOpenDay = onOpenDay
      _thread = State(initialValue: thread)
      _threadID = State(initialValue: thread?.id ?? UUID())
      _messages = State(initialValue: thread?.messages ?? [])
      _proposals = State(initialValue: (thread?.cards ?? []).map(CaptureProposal.init))
    }

    package var body: some View {
      VStack(spacing: 0) {
        // The header and editor exist only on screen: hidden pages must not leave controls in the accessibility tree.
        if isPresented { panelHeader }
        conversation
          .safeAreaInset(edge: .bottom) { inputArea }
          .task {
            // A reopened conversation starts at its end with the keyboard down; a new chat is ready to type
            // (built hidden, it takes focus in the same update that reveals it).
            if messages.isEmpty { focused = true }
            refreshCardTitles()
            #if DEBUG
              registerEvalProbe()
            #endif
          }
          .onChange(of: isPresented) { _, presented in
            if PerformanceTrace.enabled {
              PerformanceTrace.shared.mark(presented ? "chat.shown" : "chat.hidden")
            }
            focused = presented && (messages.isEmpty || !draft.isEmpty)
            if !presented { voice.stop() }
            if presented { refreshCardTitles() }
          }
          .onDisappear {
            captureTask?.cancel()
            voice.stop()
            closeOpenCards("ignored")
          }
      }
      .environment(actions)
      .environment(presentation)
      .defaultAppStorage(presentation.defaults)
      .background(Color(.systemBackground))
      .accessibilityAction(.escape) { close() }
    }

    /// Menu (past chats) on the left, Close back to the page on the right, like ChatGPT's top bar.
    var panelHeader: some View {
      HStack(spacing: 8) {
        if let onMenu {
          CircleButton(
            systemImage: "line.3.horizontal", label: "Show chats",
            size: ButtonConfiguration.minimumHitSize
          ) {
            focused = false
            voice.stop()
            onMenu()
          }
          .accessibilityIdentifier("chat.menu")
        } else {
          Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        Spacer(minLength: 0)
        Text("AI").font(.headline)
        Spacer(minLength: 0)
        CircleButton(systemImage: "xmark", label: "Close", size: ButtonConfiguration.minimumHitSize)
        {
          close()
        }
        .accessibilityIdentifier("chat.close")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    var conversation: some View {
      ScrollViewReader { proxy in
        ScrollView {
          if messages.isEmpty {
            emptyState
          } else {
            LazyVStack(alignment: .leading, spacing: 16) {
              if let subject { subjectCard(subject) }
              ForEach(messages) { message in
                MessageView(message: message).id(message.id)
                cards(under: message.id)
                agentChanges(under: message.id)
              }
              if thinking {
                HStack(spacing: 8) {
                  ProgressView()
                  Text("Thinking…").foregroundStyle(.secondary)
                }
              }
              Color.clear.frame(height: 1).id(Self.endID)
            }
            .padding(20)
            .animation(reduceMotion ? nil : .snappy, value: proposals.map(\.status))
          }
        }
        .performanceDestination("ai")
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(messages.isEmpty ? .top : .bottom, for: .initialOffset)
        .onScrollPhaseChange { previous, phase in
          scrollPhase = phase
          if phase == .idle,
            previous == .tracking || previous == .interacting || previous == .decelerating
          {
            followEnd(proxy)
          }
        }
        .onScrollGeometryChange(for: ConversationGeometry.self) { geometry in
          ConversationGeometry(
            nearEnd: geometry.contentSize.height - geometry.contentOffset.y
              - geometry.containerSize.height <= 64,
            offset: geometry.contentOffset.y,
            content: geometry.contentSize, viewport: geometry.containerSize)
        } action: { before, after in
          // Only a real pan changes reading intent. Programmatic follow animations cannot turn it off.
          if isUserScrolling, before.content == after.content, before.viewport == after.viewport,
            before.offset != after.offset
          {
            if after.nearEnd {
              followsTail = true
            } else if after.offset < before.offset {
              followsTail = false
            }
          }
          if !isUserScrolling, before.content != after.content || before.viewport != after.viewport
          {
            followEnd(proxy)
          }
        }
        .onChange(of: messages) {
          persist()
          followEnd(proxy)
        }
        .onChange(of: proposals.count) {
          followEnd(proxy)
        }
        .onChange(of: proposals) { persistCards() }

      }
    }

    // MARK: Going back

    /// Closes the screen and returns to where it was opened from (the sidebar, when opened there).
    func close() {
      focused = false
      voice.stop()
      onBack(true)
      if let onClose { onClose() } else { dismiss() }
    }

    /// Saves the conversation as it grows: the thread is created with the first user message and updated after
    /// every later message (AI replies included). Only text is kept.
    func persist() {
      guard let first = messages.first(where: { $0.role == .user }) else { return }
      if let thread {
        thread.messages = messages
        thread.subject = subject
        thread.updatedAt = now()
        // Continuing an archived conversation brings it back to the main list.
        thread.archived = false
      } else {
        let created = ChatThread(
          title: ConversationHistory.title(from: first.text), messages: messages, createdAt: now(),
          updatedAt: now(), id: threadID)
        created.subject = subject
        context.insert(created)
        thread = created
      }
      try? context.save()
    }

    var emptyState: some View {
      VStack(alignment: .leading, spacing: 24) {
        Text(subject == nil ? "What do you want to plan?" : "What about this?")
          .font(.title2.weight(.medium))
        if let subject {
          subjectCard(subject)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.top, 20)
    }

    var inputArea: some View {
      VStack(spacing: 8) {
        if !tidy.isEmpty {
          TidyCard(
            rows: $tidy, onApply: applyTidy,
            onCancel: {
              recordCard(resolved: "tidy", "cancelled", items: tidy.count)
              if let id = agentTidyID { agent?.tools.mark(id, .dropped) }
              agentTidyID = nil
              tidy = []
            }
          )
          .transition(cardTransition)
        }
        if let undo = undoRow {
          HStack(spacing: 12) {
            Text(undo.label).font(.subheadline).lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo") {
              undo.action()
              undoRow = nil
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("ask-undo")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
          .transition(cardTransition)
        }
        if openSystemEvent, let subject, let identifier = subject.itemRef,
          let start = subject.start, let native = calendarSync as? any NativeCalendarService
        {
          Button("Open in Calendar") {
            native.edit(
              identifier: identifier, start: start, end: nil, fullOptions: true, onComplete: nil)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("ask-open-system-event")
        }
        if let change {
          ChangeCard(
            change: change, onApply: { apply(change) },
            onCancel: {
              recordCard(resolved: "change", "cancelled")
              self.change = nil
            }
          )
          .transition(cardTransition)
        }
        if isPresented, !isEmpty {
          DraftMatches(
            draft: draft, tasks: tasks, events: events, now: now(),
            label: { ledger.timeLabel($0, none: "No date") },
            openTask: { onOpenTask($0, refreshCardTitles) },
            openEvent: { onOpenDay($0.start) })
        }
        // Gated like the composer: the hidden, pre-built page must not expose duplicate buttons.
        if isPresented, isEmpty || quickKind != nil, voice.state != .listening, subject == nil {
          quickKinds
        }
        HStack(alignment: .bottom, spacing: 8) {
          // Keep draft/conversation state mounted, but remove the hidden UIKit editor from AX.
          if isPresented {
            AskComposer(
              text: $draft,
              focused: Binding(get: { focused && isPresented }, set: { focused = $0 }),
              isPresented: isPresented,
              onSubmit: { send(draft) }
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
              if draft.isEmpty {
                Text(quickKind?.placeholder ?? "Ask AI or add anything")
                  .foregroundStyle(.secondary)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .padding(.vertical, 8)
          }
          if isEmpty || voice.state == .listening {
            Button {
              Task { await voice.toggle() }
            } label: {
              Image(systemName: voice.state == .listening ? "stop.circle.fill" : "mic.fill")
                .font(voice.state == .listening ? .system(size: 28) : .body)
                .foregroundStyle(voice.state == .listening ? Color.red : Color.secondary)
                .symbolEffect(.pulse, isActive: voice.state == .listening)
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(voice.state == .listening ? "Stop dictation" : "Dictate")
          } else {
            Button {
              send(draft)
            } label: {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("ask-send")
          }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
          RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 6)
      .background(Color(.systemBackground))
      .animation(reduceMotion ? nil : .snappy, value: change)
      .animation(reduceMotion ? nil : .snappy, value: followup)
      .animation(reduceMotion ? nil : .snappy, value: undoRow?.id)
      .onChange(of: voice.transcript) { _, text in
        if !text.isEmpty { draft = text }
      }
      .onChange(of: voice.state) { _, state in
        switch state {
        case .denied:
          messages.append(
            reply("Microphone or speech access is off. Turn it on in Settings to dictate."))
        case .unavailable:
          messages.append(reply("Dictation isn't available here. It works on iPhone."))
        default: break
        }
      }
    }

    /// The item this chat is about: what "it" means in the next message.
    func subjectCard(_ subject: AskSubject) -> some View {
      let symbol =
        switch subject.kind {
        case .event: "calendar"
        case .reminder: "checklist"
        case .alarm: "alarm"
        }
      return HStack(spacing: 12) {
        Image(systemName: symbol).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(subject.title).font(.body.weight(.medium)).lineLimit(2)
          Text(subject.whenLabel(calendar: runtime.calendar))
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          self.subject = nil
          thread?.subject = nil
          try? context.save()
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .accessibilityLabel("Remove item context")
        .accessibilityIdentifier("ask-subject-remove")
      }
      .padding(14)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("ask-subject")
    }

    /// Reminder / Event / Alarm: a tap selects (highlights) the kind for the next message and leaves the draft alone;
    /// tapping it again deselects. The kind's skill is added when the message is sent (`AskQuickKind`).
    var quickKinds: some View {
      HStack(spacing: 8) {
        ForEach(AskQuickKind.allCases, id: \.self) { kind in
          let selected = quickKind == kind
          Button {
            quickKind = selected ? nil : kind
            focused = true
          } label: {
            Label(kind.label, systemImage: kind.symbol)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(selected ? Color.accentColor : Color.primary)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(
                selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                in: Capsule()
              )
              .overlay(
                Capsule().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("ask-kind-\(kind.rawValue)")
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
    }

    func reply(_ text: String) -> ChatMessage {
      ChatMessage(role: .ai, text: text, timestamp: now())
    }

    var isEmpty: Bool {
      draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(_ raw: String) {
      let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !typed.isEmpty else { return }
      // The selected kind's skill is routed and parsed with the message; the chat shows what was typed.
      let text = quickKind?.request(typed) ?? typed
      quickKind = nil
      followsTail = true
      draft = ""
      captureTask?.cancel()
      thinking = false
      let turnContext = ConversationContext(
        turns: messages.map {
          .init(isUser: $0.role == .user, text: $0.text, timestamp: $0.timestamp)
        })
      let sentAt = now()
      messages.append(ChatMessage(role: .user, text: typed, timestamp: sentAt))
      turnStart = sentAt
      openSystemEvent = false
      if routeAttachedEdit(text) {
        recordTurn("edit", text)
        return
      }
      if pending == nil, SavedReminderRefinement.isRequest(text) {
        recordTurn("edit", text)
        guard let receipt = proposals.last, receipt.status == .added,
          let ref = receipt.itemRef,
          case .task(let task)? = CaptureUndo.resolve(ref, in: context),
          !task.isDone, let due = task.due, !task.ringsAsAlarm
        else {
          messages.append(
            reply("Which saved reminder should repeat every day? Open it to edit its repeat rule."))
          return
        }
        var capture = receipt.capture
        capture.title = task.title
        capture.day = runtime.calendar.startOfDay(for: due)
        capture.hasDay = true
        capture.hour = runtime.calendar.component(.hour, from: due)
        capture.minute = runtime.calendar.component(.minute, from: due)
        capture.repeatRule = task.repeatRule
        guard
          let refined = SavedReminderRefinement.preview(
            capture, text: text, now: now(), calendar: runtime.calendar)
        else {
          messages.append(
            reply(
              "Should this reminder repeat every day at its current time? Please open it to confirm the repeat rule."
            ))
          return
        }
        clearPreviews()
        change = PendingChange(
          subject: .task(task), delete: false, title: task.title,
          oldText: plannerDayLabel(due, runtime: runtime),
          newStart: refined.taskTiming(calendar: runtime.calendar).due,
          notes: ["Repeat every day. Nothing changes until you tap Apply."], attendees: 0)
        change?.newRepeatRule = refined.repeatRule
        change?.expectedTask = Ledger.snapshot(of: task)
        return
      }
      let route = AskRouter.plan(
        text, context: turnContext, pending: pending,
        savedDraft: proposals.last.map { $0.status != .open } ?? false,
        agentHasOpenCards: agent?.hasOpenCards ?? false,
        hasLocalTimeContext: hasLocalTimeContext, editItems: { editItems() },
        now: sentAt, calendar: runtime.calendar)
      let decision = route.decision
      if let answer = route.previewAnswer, answerOpenPreview(answer) {
        recordTurn("answer", text)
        return
      }
      // Everything else FastLane doesn't take goes to the agent (§4.1).
      if route.useAgent {
        // Not signed in to Luna AI: rules only, no request (§4.7 #3).
        guard agentModel.isAvailable() else {
          runLocally(text, typed: typed, error: .unavailable)
          return
        }
        runAgent(typed: typed, text: text, anchor: messages.last?.id ?? UUID())
        return
      }
      switch decision {
      case .clarifyCorrection:
        recordTurn("clarify", text)
        messages.append(
          reply(
            text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
              ? "请重新说一次要提醒的事项、日期和时间，避免用错日期。还没有添加任何事项。"
              : "Please restate the item, date and time so I use the corrected date. Nothing has been added."
          ))
        return
      case .directReminder(let capture):
        recordTurn("capture", text)
        clearPreviews()
        createSubmittedReminder(capture)
        recordFastLaneReceipt(typed: typed)
        return
      case .continuation(let resolved, let direct):
        recordTurn("answer", text)
        if direct {
          // A subjectless continuation never duplicates a previously decided card, including
          // after reopening the chat. Undo/Cancel require a deliberate Add again/new request.
          if let existing = proposals.last(where: {
            FastLane.sameOneOff($0.capture, resolved)
          }) {
            if existing.status == .open {
              commit(existing.id)
            } else {
              messages.append(
                reply(
                  existing.status == .added
                    ? "Already added. Use Open or Undo on the reminder."
                    : "Use the card to add it again."))
            }
          } else {
            clearPreviews()
            createSubmittedReminder(resolved)
          }
          return
        }
        if pending != nil {
          pending = resolved
        } else {
          clearPreviews()
          show([resolved])
        }
        if resolved.hour == nil && resolved.ringsAsAlarm {
          followup = .alarmTime
          messages.append(
            reply(
              text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                ? "闹钟要设在几点？确认添加后才会生效。"
                : "What time should the alarm ring? Nothing is added until you confirm."))
        } else {
          followup = nil
          messages.append(
            reply(
              text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                ? "预览已更新，点 Add 后才会添加。" : "The preview is ready. Tap Add to create it."))
        }
        return
      case .notFastLane: break
      }
    }

    /// A preview of FastLane's own is open (or the last turn asked for an alarm's time).
    var hasLocalTimeContext: Bool {
      followup == .alarmTime || pending != nil || (change != nil && change?.delete == false)
    }

    /// Reads `text` as an answer to FastLane's own open preview or change card. False: something new.
    func answerOpenPreview(_ text: String) -> Bool {
      let now = now()
      let cal = runtime.calendar
      if followup == .alarmTime, let capture = pending,
        case .updated(let c) = FastLane.refine(
          capture, with: "alarm " + text, now: now, calendar: cal)
      {
        followup = nil
        pending = c
        messages.append(reply("Set as an alarm. Nothing is added until you confirm."))
        return true
      }
      if pending != nil || change != nil,
        FastLane.refine(
          Capture(title: "_", day: now, hasDay: false), with: text, now: now, calendar: cal)
          == .dismissed
      {
        clearPreviews()
        messages.append(reply("OK, dropped it."))
        return true
      }
      if let capture = pending {
        switch FastLane.refine(capture, with: text, now: now, calendar: cal) {
        case .updated(let c):
          pending = c
          messages.append(reply("Updated. Nothing is added until you confirm."))
          return true
        case .needsTime:
          followup = .alarmTime
          messages.append(reply("What time should it ring?"))
          return true
        case .dismissed, .notARefinement:
          break
        }
      }
      if let current = change, !current.delete,
        FastLane.isOnlyWhen(text, now: now, calendar: cal),
        let new = FastLane.answerTime(text, keeping: current.newStart, now: now, calendar: cal)
      {
        var updated = current
        updated.newStart = new
        change = updated
        messages.append(reply("Updated. Nothing changes until you apply it."))
        return true
      }
      return false
    }

    /// Moving on drops pending cards in place, recording their resolution without removing chat history.
    func clearPreviews() {
      closeOpenCards("ignored")
      dropOpenCards()
      agent?.dropOpenChanges()
      if let id = agentTidyID, !tidy.isEmpty { agent?.tools.mark(id, .dropped) }
      agentTidyID = nil
      change = nil
      tidy = []
      undoRow = nil
      followup = nil
    }

    /// The first item still waiting for Add: what a follow-up like "make it 5pm" edits. Setting nil drops them all.
    var pending: Capture? {
      get {
        // Continuations only ever complete FastLane's own drafts, never an agent card (§4.2).
        guard let batch = proposals.last(where: { $0.agentID == nil })?.batch else { return nil }
        return proposals.first { $0.batch == batch && $0.status == .open }?.capture
      }
      nonmutating set {
        guard let newValue else {
          dropOpenCards()
          return
        }
        if let batch = proposals.last(where: { $0.agentID == nil })?.batch,
          let i = proposals.firstIndex(where: { $0.batch == batch && $0.status == .open })
        {
          guard proposals[i].pendingExternalID == nil else { return }
          proposals[i].capture = newValue
        }
      }
    }

    // MARK: Multi-turn

    /// What the last turn left open: "what time should the alarm ring?" for FastLane's own preview.
    enum Followup: Equatable {
      case alarmTime
    }

  }
  #if DEBUG
    // MARK: Evaluation probe (AskEvalProbe; docs/qa/agent-p3-eval-20261101.md)

    extension AskView {
      fileprivate func registerEvalProbe() {
        guard let probe = AskEvalProbe.current else { return }
        probe.send = { send($0) }
        probe.snapshot = { evalSnapshot() }
        probe.applyChange = {
          if let agent, let open = agent.changes.last(where: { $0.status == .open }) {
            await agent.apply(open.id)
          }
        }
      }

      /// What the chat shows: replies, capture cards (incl. FastLane receipts) and agent change cards.
      fileprivate func evalSnapshot() -> JSONValue {
        let cal = runtime.calendar
        let shown: [JSONValue] = proposals.map { p in
          var o = AskEvalProbe.capture(p.capture, calendar: cal)
          o["id"] = .string(p.id.uuidString)
          o["status"] = .string(p.status.rawValue)
          o["batch"] = .string(p.batch.uuidString)
          o["agent"] = .bool(p.agentID != nil)
          if let ref = p.itemRef { o["item"] = .string(Ledger.comparisonKey(ref)) }
          return .object(o)
        }
        return [
          "thinking": .bool(thinking),
          "messages": .array(
            messages.map {
              ["role": .string($0.role == .user ? "user" : "ai"), "text": .string($0.text)]
            }),
          "proposals": .array(shown),
          "agent_changes": .array(
            (agent?.changes ?? []).map { AskEvalProbe.agentChange($0, calendar: cal) }),
          "tidy": .number(Double(tidy.count)),
          "draft": .string(draft),
        ]
      }
    }
  #endif
#endif

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    private let isPresented: Bool
    private let onClose: (() -> Void)?
    /// Opens the sidebar (past chats); no menu button when nil.
    private let onMenu: (() -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(UndoToast.self) private var toast: UndoToast?
    @Query(sort: \OneTask.createdAt) private var tasks: [OneTask]
    @Query(sort: \OneEvent.start) private var events: [OneEvent]

    private let calendarSync: any CalendarService
    private let actions: PlannerActions
    private let ledger: Ledger
    private let activity: ActivityCenter
    private let intelligence: AskIntelligence
    private let presentation: PlannerPresentation
    private let travel: any TravelTimeProviding
    private let suggestionMemory: AskSuggestionMemory
    private var runtime: PlannerRuntime { presentation.runtime }
    private let now: () -> Date
    /// The item this chat was opened about (its "Ask AI" menu row); nil for an ordinary chat.
    @State private var subject: AskSubject?

    let onAdded: (Capture) -> Void
    /// Asks the presenter to show what this screen goes back to (`true`), underneath it, or to undo that
    /// when a back swipe is cancelled (`false`). Called before the screen closes, by the close button or a swipe.
    let onBack: (Bool) -> Void
    /// "Open" on an added event: closes this screen and shows that day in Today.
    let onOpenDay: (Date) -> Void

    /// The saved conversation this screen continues. nil = a new chat; the thread is created on the first user message.
    @State private var thread: ChatThread?
    /// The chat's id from the first message on (the saved thread takes it), so Activity data events can point at it.
    @State private var threadID: UUID
    /// When the last message was sent / the last card appeared: latency and dwell time for Activity data.
    @State private var turnStart: Date
    @State private var cardShownAt: Date?
    @State private var messages: [ChatMessage]
    @State private var draft = ""
    /// The Reminder / Event / Alarm button the user selected for the next message (`AskQuickKind`).
    @State private var quickKind: AskQuickKind?
    @State private var followsTail = true
    @State private var scrollPhase: ScrollPhase = .idle

    private struct ConversationGeometry: Equatable {
      let nearEnd: Bool
      let offset: CGFloat
      let content: CGSize
      let viewport: CGSize
    }

    private var isUserScrolling: Bool {
      scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating
    }

    private var cardTransition: AnyTransition {
      reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private func followEnd(_ proxy: ScrollViewProxy) {
      guard followsTail else { return }
      withAnimation(reduceMotion ? nil : .default) {
        proxy.scrollTo(Self.endID, anchor: .bottom)
      }
    }
    /// The preview cards of this conversation, each under the AI message that proposed it. They stay after Add / Cancel
    /// (Added, Dropped, Undone) and are saved with the conversation.
    @State private var proposals: [CaptureProposal] = []
    /// Shell presents the typed editor above this Ask modal and calls the supplied handler on dismiss.
    private let onOpenTask: (OneTask, @escaping () -> Void) -> Void
    private let onOpenAlarm: (OneAlarm, @escaping () -> Void) -> Void

    private static let endID = "chat-end"
    @Query(sort: \OneList.order) private var lists: [OneList]
    @AppStorage private var showsSuggestions: Bool
    @State private var thinking = false
    /// The agent side of this conversation (flag `today.ai.agent`); created on its first use.
    @State private var agent: AskAgentSession?
    /// The Tidy card the agent prepared, so Apply/Cancel are recorded against its proposal.
    @State private var agentTidyID: String?
    @State private var captureTask: Task<Void, Never>?
    /// Diagnostic-only identity: production cancellation behavior stays unchanged when tracing is off.
    @State private var generationToken = UUID()
    @State private var emittedTurn: UUID?
    @State private var responseTurn: UUID?
    @State private var sentMessageID: UUID?
    @State private var responseTarget: ResponseTarget?
    @State private var responseBaseline: ResponseSignature?

    private enum ResponseTarget: Equatable {
      case reply(UUID)
      case capture(UUID)
      case tidy
      case change(UUID)
      case choices([UUID])
    }

    private struct ResponseSignature: Equatable {
      let messages: [ChatMessage]
      let proposals: [CaptureProposal]
      let followup: Followup?
      let change: PendingChange?
      let changeStart: Date?
      let tidy: [String]
    }

    private var responseSignature: ResponseSignature? {
      guard AIResponseTrace.enabled else { return nil }
      return ResponseSignature(
        messages: messages, proposals: proposals, followup: followup, change: change,
        changeStart: change?.newStart,
        tidy: tidy.map { "\($0.id):\($0.choice)" })
    }

    /// A state mutation alone cannot finish a turn. Its own synchronous/async handler must first emit a result.
    private func finishEmission(_ token: UUID) {
      if AIResponseTrace.enabled {
        AIResponseTrace.shared.stage("finish_emission_enter", token: token)
      }
      guard AIResponseTrace.enabled, token == generationToken, !thinking,
        let signature = responseSignature, let baseline = responseBaseline,
        signature != baseline
      else { return }
      if signature.proposals != baseline.proposals,
        let proposal = proposals.last(where: { p in
          baseline.proposals.first(where: { $0.id == p.id }) != p && p.status == .open
        })
      {
        responseTarget = .capture(proposal.batch)
      } else if !tidy.isEmpty && signature.tidy != baseline.tidy {
        responseTarget = .tidy
      } else if let change,
        signature.change != baseline.change || signature.changeStart != baseline.changeStart
      {
        responseTarget = .change(change.id)
      } else if case .chooseItem(_, let options)? = followup,
        signature.followup != baseline.followup
      {
        responseTarget = .choices(options.map(\.id))
      } else if let reply = messages.last(where: { $0.role == .ai }),
        reply.id != baseline.messages.last(where: { $0.role == .ai })?.id
      {
        responseTarget = .reply(reply.id)
      } else {
        return
      }
      emittedTurn = token
      AIResponseTrace.shared.stage("finish_emission_assigned", token: token)
    }

    @ViewBuilder private func responseProbe(_ target: ResponseTarget) -> some View {
      if AIResponseTrace.enabled, responseTarget == target, let responseTurn {
        AIResponseContentProbe(token: responseTurn, phase: .response)
      }
    }

    private func traceBackend(_ token: UUID, modelPath: Bool) {
      guard AIResponseTrace.enabled else { return }
      // Public AI APIs hide timeout/empty-result fallback, so availability is never claimed as model success.
      let backend: String
      if !modelPath {
        backend = "rules"
      } else {
        switch intelligence.backend() {
        case .hosted: backend = "hosted_available_outcome_unobserved"
        case .rules: backend = "fallback_model_unavailable"
        case .scripted: backend = "development_scripted"
        }
      }
      AIResponseTrace.shared.backend(backend, token: token)
    }
    /// "Tidy overdue": a new date per overdue reminder, waiting for Apply.
    @State private var tidy: [TidyRow] = []
    @State private var voice: VoiceInput
    @State private var change: PendingChange?
    @State private var openSystemEvent = false
    @State private var undoRow: UndoRow?
    /// What the last turn left open (a "which one?" with real items, or a "when?"), so the next message can answer it.
    @State private var followup: Followup?
    /// Title of the item the conversation touched last: what "it" means.
    @State private var lastTouched: String?
    @State private var focused = false

    package init(
      thread: ChatThread? = nil, subject: AskSubject? = nil, isPresented: Bool = true,
      onClose: (() -> Void)? = nil,
      onMenu: (() -> Void)? = nil, calendar: any CalendarService, now: @escaping () -> Date,
      actions: PlannerActions, ledger: Ledger, activity: ActivityCenter,
      intelligence: AskIntelligence, voice: VoiceInput, presentation: PlannerPresentation,
      travel: any TravelTimeProviding, suggestionMemory: AskSuggestionMemory,
      onBack: @escaping (Bool) -> Void, onAdded: @escaping (Capture) -> Void,
      onOpenDay: @escaping (Date) -> Void,
      onOpenTask: @escaping (OneTask, @escaping () -> Void) -> Void,
      onOpenAlarm: @escaping (OneAlarm, @escaping () -> Void) -> Void
    ) {
      let attached = thread?.subject ?? subject
      _subject = State(initialValue: attached)
      // "it" means this item until the conversation touches another one.
      _lastTouched = State(initialValue: attached?.title)
      self.isPresented = isPresented
      self.onClose = onClose
      self.onMenu = onMenu
      self.calendarSync = calendar
      self.now = now
      self.actions = actions
      self.ledger = ledger
      self.activity = activity
      self.intelligence = intelligence
      self.presentation = presentation
      self.travel = travel
      self.suggestionMemory = suggestionMemory
      _voice = State(initialValue: voice)
      _turnStart = State(initialValue: now())
      _showsSuggestions = AppStorage(
        wrappedValue: Preferences.askSuggestions, Preferences.askSuggestionsKey,
        store: presentation.defaults)
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
            intelligence.prewarm()
          }
          .onChange(of: isPresented) { _, presented in
            if PerformanceTrace.enabled {
              PerformanceTrace.shared.mark(presented ? "chat.shown" : "chat.hidden")
            }
            focused = presented && (messages.isEmpty || !draft.isEmpty)
            if !presented { voice.stop() }
            if presented { refreshCardTitles() }
          }
          .onChange(of: emittedTurn) { _, token in
            if AIResponseTrace.enabled, let token {
              AIResponseTrace.shared.stage("on_change_enter", token: token)
            }
            guard let token, token == generationToken, !thinking,
              responseSignature != responseBaseline
            else { return }
            AIResponseTrace.shared.ready(token)
            responseTurn = token
          }
          .onDisappear {
            captureTask?.cancel()
            voice.stop()
            closeOpenCards("ignored")
            if AIResponseTrace.enabled { AIResponseTrace.shared.cancel(generationToken) }
          }
      }
      .environment(actions)
      .environment(presentation)
      .defaultAppStorage(presentation.defaults)
      .background(Color(.systemBackground))
      .accessibilityAction(.escape) { close() }
      .overlay(alignment: .topTrailing) { AIResponseTraceHistory() }
    }

    /// Menu (past chats) on the left, Close back to the page on the right, like ChatGPT's top bar.
    private var panelHeader: some View {
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

    private var conversation: some View {
      ScrollViewReader { proxy in
        ScrollView {
          if messages.isEmpty {
            emptyState
          } else {
            LazyVStack(alignment: .leading, spacing: 16) {
              if let subject { subjectCard(subject) }
              ForEach(messages) { message in
                MessageView(message: message).id(message.id)
                  .background {
                    if AIResponseTrace.enabled, message.id == sentMessageID {
                      AIResponseContentProbe(token: generationToken, phase: .feedback)
                    }
                    responseProbe(.reply(message.id))
                  }
                cards(under: message.id)
                agentChanges(under: message.id)
              }
              if thinking {
                HStack(spacing: 8) {
                  ProgressView()
                  Text("Thinking…").foregroundStyle(.secondary)
                }
                .background {
                  if AIResponseTrace.enabled {
                    AIResponseContentProbe(token: generationToken, phase: .feedback)
                  }
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
          if AIResponseTrace.enabled {
            AIResponseTrace.shared.stage("persist_before", token: generationToken)
          }
          persist()
          if AIResponseTrace.enabled {
            AIResponseTrace.shared.stage("persist_after", token: generationToken)
            AIResponseTrace.shared.stage("scroll_request_before", token: generationToken)
          }
          followEnd(proxy)
          if AIResponseTrace.enabled {
            AIResponseTrace.shared.stage("scroll_request_after", token: generationToken)
          }
        }
        .onChange(of: proposals.count) {
          followEnd(proxy)
        }
        .onChange(of: proposals) { persistCards() }

      }
    }

    // MARK: Going back

    /// Closes the screen and returns to where it was opened from (the sidebar, when opened there).
    private func close() {
      focused = false
      voice.stop()
      onBack(true)
      if let onClose { onClose() } else { dismiss() }
    }

    /// Saves the conversation as it grows: the thread is created with the first user message and updated after
    /// every later message (AI replies included). Only text is kept.
    private func persist() {
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

    private var emptyState: some View {
      VStack(alignment: .leading, spacing: 24) {
        Text(subject == nil ? "What do you want to plan?" : "What about this?")
          .font(.title2.weight(.medium))
        if let subject {
          subjectCard(subject)
        }
        // Built with the hidden page, so the chips are ready when it opens.
        if showsSuggestions, subject == nil {
          AskSuggestionList(
            calendar: calendarSync, now: now, presentation: presentation, travel: travel,
            activity: activity, intelligence: intelligence, memory: suggestionMemory,
            isVisible: isPresented, onSend: send)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.top, 20)
    }

    private var inputArea: some View {
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
          .background { responseProbe(.tidy) }
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
        if case .chooseItem(_, let options)? = followup {
          ChoiceBar(options: options, onPick: tapChoice)
            .background { responseProbe(.choices(options.map(\.id))) }
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
          .background { responseProbe(.change(change.id)) }
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
    private func subjectCard(_ subject: AskSubject) -> some View {
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
          lastTouched = nil
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
    private var quickKinds: some View {
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

    private func reply(_ text: String) -> ChatMessage {
      ChatMessage(role: .ai, text: text, timestamp: now())
    }

    private var isEmpty: Bool {
      draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ raw: String) {
      let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !typed.isEmpty else { return }
      // The selected kind's skill is routed and parsed with the message; the chat shows what was typed.
      let text = quickKind?.request(typed) ?? typed
      quickKind = nil
      followsTail = true
      let token = AIResponseTrace.enabled ? UUID() : generationToken
      if AIResponseTrace.enabled {
        AIResponseTrace.shared.begin(token, modelAvailable: intelligence.backend() == .hosted)
        generationToken = token
        emittedTurn = nil
        responseTurn = nil
        responseTarget = nil
      }
      defer { finishEmission(token) }
      draft = ""
      captureTask?.cancel()
      thinking = false
      var turnContext = ConversationContext(
        turns: messages.map {
          .init(isUser: $0.role == .user, text: $0.text, timestamp: $0.timestamp)
        })
      turnContext.subject = subject?.contextLine(calendar: runtime.calendar) ?? ""
      let history = turnContext.prompt
      if AIResponseTrace.enabled { AIResponseTrace.shared.stage("context_complete", token: token) }
      let sentAt = now()
      messages.append(ChatMessage(role: .user, text: typed, timestamp: sentAt))
      if AIResponseTrace.enabled {
        sentMessageID = messages.last?.id
        responseBaseline = responseSignature
      }
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
      let intent = FastLane.intent(text)
      // Rule gates first, in this order; only `.directReminder` writes without a card.
      let decision = FastLane.decide(
        text, intent: intent, context: turnContext, pending: pending,
        savedDraft: proposals.last.map { $0.status != .open } ?? false,
        editItems: { editCandidates().items }, now: sentAt, calendar: runtime.calendar)
      // With the agent on, everything FastLane doesn't take goes to the agent (§4.1).
      if agentEnabled,
        AgentRouting.useAgent(decision, agentHasOpenCards: agent?.hasOpenCards ?? false)
      {
        // Not signed in to Luna AI: rules only, no request (§4.7 #3).
        guard HostedLunaClient().isAvailable else {
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
        if agentEnabled { recordFastLaneReceipt(typed: typed) }
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
      // A question-shaped answer to our time prompt may edit a preview; other conversation cannot.
      let hasTimeContext: Bool
      switch followup {
      case .needTime, .alarmTime: hasTimeContext = true
      case .chooseItem: hasTimeContext = false
      case nil: hasTimeContext = pending != nil || (change != nil && change?.delete == false)
      }
      if let answer = ChatRouting.contextualTimeAnswer(text, hasTimeContext: hasTimeContext),
        answerOpenTurn(answer, history: history)
      {
        recordTurn("answer", text)
        return
      }
      // Clear conversation must not be mistaken for a follow-up that changes a pending card.
      if intent == .conversation {
        if ChatRouting.isAgendaQuestion(text) {
          recordTurn("question", text)
          messages.append(reply(todaySummary))
        } else {
          respond(text, context: turnContext, intent: intent)
        }
        return
      }
      // Explicit supported operations go to their handlers, not broad preview/time refinement.
      // Other messages may answer what the last turn left open, or edit the preview that is showing.
      if !ChatRouting.isSupportedOperationRequest(text), answerOpenTurn(text, history: history) {
        recordTurn("answer", text)
        return
      }
      if OverdueTidy.isRequest(text) {
        recordTurn("tidy", text)
        clearPreviews()
        proposeTidy()
      } else if Editing.looksLikeEdit(
        text, items: editCandidates().items, now: now(), calendar: runtime.calendar)
      {
        recordTurn("edit", text)
        clearPreviews()
        proposeEdit(text, history: history)
      } else {
        respond(text, context: turnContext, intent: intent)
      }
    }

    /// Resolve an explicit anaphoric edit against the selected identity, never a matching title.
    private func routeAttachedEdit(_ text: String) -> Bool {
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
          present(
            EditDecision(op: .move, target: "attached", newStart: date, reason: "attached"),
            id: "attached", candidates: ([candidate], [:], ["attached": event]))
          return true
        case .delete:
          present(
            EditDecision(op: .delete, target: "attached", reason: "attached"),
            id: "attached", candidates: ([candidate], [:], ["attached": event]))
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

    /// Route before either extractor. Conversation leaves pending previews and follow-ups untouched.
    private func respond(_ text: String, context: ConversationContext, intent: ChatRouting.Intent) {
      let history = context.prompt
      if AIResponseTrace.enabled, intent == .conversation {
        AIResponseTrace.shared.diagnoseConversation(generationToken)
        AIResponseTrace.shared.stage("respond_enter", token: generationToken)
      }
      // Record the sent interaction before cancellation can discard its reply. The model has not resolved unsure input yet.
      let initialIntent: String
      switch intent {
      case .capture: initialIntent = "capture"
      case .conversation: initialIntent = "conversation"
      case .unsure: initialIntent = "unsure"
      }
      if AIResponseTrace.enabled, intent == .conversation {
        AIResponseTrace.shared.stage("record_turn_before", token: generationToken)
      }
      recordTurn(initialIntent, text)
      if AIResponseTrace.enabled, intent == .conversation {
        AIResponseTrace.shared.stage("record_turn_after", token: generationToken)
      }
      if let reply = ChatRouting.contextReply(text, context: context) {
        messages.append(self.reply(reply))
        return
      }
      thinking = true
      traceBackend(generationToken, modelPath: intent != .capture)
      let token = generationToken
      if intent == .conversation && !intelligence.isAvailable() {
        if AIResponseTrace.enabled { AIResponseTrace.shared.localReply(.before, token: token) }
        thinking = false
        messages.append(reply(ChatRouting.fallbackReply(text)))
        if AIResponseTrace.enabled { AIResponseTrace.shared.localReply(.after, token: token) }
        return
      }
      captureTask = Task { @MainActor in
        if AIResponseTrace.enabled, intent == .conversation {
          AIResponseTrace.shared.stage("task_enter", token: token)
        }
        defer { finishEmission(token) }
        if AIResponseTrace.enabled, intent == .conversation {
          AIResponseTrace.shared.stage("chat_response_await_before", token: token)
        }
        let result = await intelligence.respond(text, history, intent)
        if AIResponseTrace.enabled, intent == .conversation {
          AIResponseTrace.shared.stage("chat_response_await_after", token: token)
        }
        guard !Task.isCancelled, !AIResponseTrace.enabled || token == generationToken else {
          return
        }
        thinking = false
        switch result {
        case .capture:
          clearPreviews()
          propose(text, history: history)
        case .reply(let reply):
          messages.append(self.reply(reply))
        }
      }
    }

    /// Moving on drops pending cards in place, recording their resolution without removing chat history.
    private func clearPreviews() {
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

    // MARK: Activity data (tier 2)

    /// The routing of one message: where it went, and how long and in what language it was. The text itself is not copied
    /// unless the user switched that on (Settings → Activity data).
    private func recordTurn(_ intent: String, _ text: String, route: String = "rules") {
      // This describes the initial routing decision, before any model response or extraction.
      activity.record(
        ActivityEvents.aiTurn(
          intent: intent, route: route, text: text,
          keepText: activity.settings.keepChatText, thread: threadID))
    }

    private func recordCard(shown card: String, items: Int) {
      cardShownAt = now()
      activity.record(
        ActivityEvents.cardShown(
          card: card, items: items,
          latencyMs: Int(now().timeIntervalSince(turnStart) * 1000), thread: threadID))
    }

    private func recordCard(
      resolved card: String, _ outcome: String, items: Int = 1, edits: [ActivityContent] = []
    ) {
      let dwell = cardShownAt.map { Int(now().timeIntervalSince($0) * 1000) }
      activity.record(
        ActivityEvents.cardResolved(
          card: card, outcome: outcome, edits: edits, items: items, dwellMs: dwell, thread: threadID
        ))
    }

    /// Cards still waiting for a tap when they go away (a new message, the screen closing) are recorded as ignored.
    private func closeOpenCards(_ outcome: String) {
      if !tidy.isEmpty { recordCard(resolved: "tidy", outcome, items: tidy.count) }
      let open = proposals.filter { $0.status == .open }.count
      if open > 0 { recordCard(resolved: "capture", outcome, items: open) }
      if change != nil { recordCard(resolved: "change", outcome) }
    }

    private func dropOpenCards() {
      for i in proposals.indices where !proposals[i].retainsDraft {
        if let next = proposals[i].status.after(.drop) {
          proposals[i].status = next
          if let id = proposals[i].agentID { agent?.tools.mark(id, .dropped) }
        }
      }
    }

    /// The first item still waiting for Add: what a follow-up like "make it 5pm" edits. Setting nil drops them all.
    private var pending: Capture? {
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

    /// A turn that asked something. The options are real items; tapping one and typing "the second one" take the same path.
    enum Followup: Equatable {
      case chooseItem(text: String, options: [ChoiceOption])
      case needTime(ChoiceOption)
      case alarmTime
    }

    struct ChoiceOption: Identifiable, Equatable {
      let id = UUID()
      let title: String
      let type: String
      let when: Date?
    }

    /// Reads `text` as the answer to the previous turn. False means it is something new.
    private func answerOpenTurn(_ text: String, history: String) -> Bool {
      let now = now()
      let cal = runtime.calendar
      switch followup {
      case .chooseItem(let original, let options):
        if let i = Dialogue.answerToWhichOne(text, from: options.map(\.title)) {
          followup = nil
          choose(options[i], original: original, history: history)
          return true
        }
      case .needTime(let option):
        let candidates = editCandidates()
        if let item = fresh(option, in: candidates.items) {
          if let start = Dialogue.answerTime(text, keeping: item.start, now: now, calendar: cal) {
            followup = nil
            present(
              EditDecision(op: .move, target: item.id, newStart: start, reason: "ok"), id: item.id,
              candidates: candidates)
            return true
          }
        } else {
          followup = nil
        }
      case .alarmTime:
        if let capture = pending,
          case .updated(let c) = Dialogue.refine(
            capture, with: "alarm " + text, now: now, calendar: cal)
        {
          followup = nil
          pending = c
          messages.append(reply("Set as an alarm. Nothing is added until you confirm."))
          return true
        }
      case nil: break
      }

      if Dialogue.refine(
        Capture(title: "_", day: now, hasDay: false), with: text, now: now, calendar: cal)
        == .dismissed, pending != nil || change != nil
      {
        clearPreviews()
        followup = nil
        messages.append(reply("OK, dropped it."))
        return true
      }
      if let capture = pending {
        switch Dialogue.refine(capture, with: text, now: now, calendar: cal) {
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
      if let current = change, !current.delete, Dialogue.isOnlyWhen(text, now: now, calendar: cal),
        let new = Dialogue.answerTime(text, keeping: current.newStart, now: now, calendar: cal)
      {
        var updated = current
        updated.newStart = new
        change = updated
        messages.append(reply("Updated. Nothing changes until you apply it."))
        return true
      }
      return false
    }

    /// The item for an option, looked up again in today's candidates (ids are only valid within one request).
    private func fresh(_ option: ChoiceOption, in items: [EditItem]) -> EditItem? {
      items.first { $0.title == option.title && $0.type == option.type }
    }

    private func option(_ item: EditItem) -> ChoiceOption {
      ChoiceOption(title: item.title, type: item.type, when: item.start)
    }

    /// The user picked one of the offered items (tap or words): continue the sentence that raised the question.
    private func choose(_ option: ChoiceOption, original: String, history: String) {
      let candidates = editCandidates()
      guard let item = fresh(option, in: candidates.items) else {
        messages.append(reply("“\(option.title)” isn't in your next week any more."))
        return
      }
      let d = Editing.decide(
        text: original, chosen: item, delete: false, now: now(), calendar: runtime.calendar)
      handle(d, text: original, plan: nil, candidates: candidates, history: history)
    }

    private func tapChoice(_ option: ChoiceOption) {
      guard case .chooseItem(let original, _)? = followup else { return }
      followsTail = true
      messages.append(ChatMessage(role: .user, text: option.title))
      followup = nil
      choose(
        option, original: original,
        history: Dialogue.recap(messages.map { ($0.role == .user, $0.text) }))
    }

    /// On-device model when available, scripted parser otherwise. Only produces the preview card.
    private func understand(_ text: String, history: String = "") {
      thinking = true
      traceBackend(generationToken, modelPath: true)
      let token = generationToken
      let anchor = turnStart
      captureTask = Task { @MainActor in
        defer { finishEmission(token) }
        let capture = await intelligence.parse(text, history, anchor, runtime.calendar)
        guard !Task.isCancelled, !AIResponseTrace.enabled || token == generationToken else {
          return
        }
        thinking = false
        show([capture])
        if capture.ringsAsAlarm, capture.hour == nil {
          pending = capture
          followup = .alarmTime
          messages.append(
            reply(
              text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                ? "闹钟要设在几点？确认添加后才会生效。"
                : "What time should the alarm ring? Nothing is added until you confirm."))
        }
      }
    }

    // MARK: Editing existing items

    /// Open tasks and the next week's events, with short ids the model can point at.
    private func editCandidates() -> (
      items: [EditItem], tasks: [String: OneTask], events: [String: OneEvent]
    ) {
      EditCandidates.build(
        events: events, tasks: tasks, calendarSync: calendarSync, now: now(),
        calendar: runtime.calendar)
    }

    /// Edit sentence → a ChangeCard, a question in the chat, or (not an edit after all) a capture. Nothing is written here.
    private func proposeEdit(_ text: String, history: String) {
      let candidates = editCandidates()
      // The words usually settle which item is meant; the model is asked only when they do not.
      guard
        Editing.needsModel(text, items: candidates.items, now: now(), calendar: runtime.calendar)
      else {
        handle(
          Editing.decide(
            text: text, plan: nil, items: candidates.items, now: now(), calendar: runtime.calendar,
            focus: focusItem(candidates.items)),
          text: text, plan: nil, candidates: candidates, history: history)
        return
      }
      guard intelligence.unavailableReason(runtime.locale.identifier) == nil else {
        messages.append(
          reply(
            "The AI service isn't available, so I can't tell which item you mean from that sentence. Name the item, or open it to edit it."
          ))
        return
      }
      thinking = true
      traceBackend(generationToken, modelPath: true)
      let token = generationToken
      captureTask = Task { @MainActor in
        defer { finishEmission(token) }
        let items = candidates.items
        let modelPlan = intelligence.plan
        let anchor = now()
        let calendar = runtime.calendar
        let plan = await ModelTimeout.run(seconds: 20) {
          try? await modelPlan(text, items, anchor, calendar, history)
        }
        guard !Task.isCancelled, !AIResponseTrace.enabled || token == generationToken else {
          return
        }
        thinking = false
        if plan == nil {
          messages.append(
            reply(
              "The AI service didn't answer in time. Try again in a moment, or name the item.")
          )
          return
        }
        handle(
          Editing.decide(
            text: text, plan: plan?.pick, items: items, now: now(), calendar: runtime.calendar,
            focus: focusItem(items)),
          text: text, plan: plan, candidates: candidates, history: history)
      }
    }

    private func focusItem(_ items: [EditItem]) -> EditItem? {
      lastTouched.flatMap { title in items.first { $0.title == title } }
    }

    private func handle(
      _ decision: EditDecision, text: String, plan: EditPlan?,
      candidates: (items: [EditItem], tasks: [String: OneTask], events: [String: OneEvent]),
      history: String
    ) {
      switch decision.op {
      case .none:
        propose(text)
      case .clarify:
        clarify(decision, text: text, plan: plan, items: candidates.items)
      case .move, .delete:
        guard let id = decision.target else { return }
        present(decision, id: id, candidates: candidates)
      }
    }

    /// Asks one question and remembers it. When the answer is a choice between items, the choices are real items and are tappable.
    private func clarify(_ d: EditDecision, text: String, plan: EditPlan?, items: [EditItem]) {
      if d.reason.hasPrefix("several items match:") {
        let ids = d.reason.dropFirst("several items match:".count).split(separator: ",").map {
          String($0).trimmingCharacters(in: .whitespaces)
        }
        let options = ids.compactMap { id in items.first { $0.id == id } }.prefix(5).map(option)
        followup = .chooseItem(text: text, options: Array(options))
        messages.append(reply("Which one do you mean?"))
      } else if d.reason == "no new time", let id = d.target,
        let item = items.first(where: { $0.id == id })
      {
        followup = .needTime(option(item))
        messages.append(reply("When should I move “\(item.title)” to?"))
      } else if d.reason == "no item named", !items.isEmpty {
        followup = .chooseItem(text: text, options: items.prefix(5).map(option))
        messages.append(reply("Which item do you mean?"))
      } else {
        messages.append(reply(clarifyQuestion(d, plan: plan, items: items)))
      }
    }

    private func clarifyQuestion(_ d: EditDecision, plan: EditPlan?, items: [EditItem]) -> String {
      switch d.reason {
      case "several items": return "I change one item at a time. Which one first?"
      case "model unavailable":
        return "I couldn't read that. Try rephrasing, or open the item to edit it."
      default: return "Which item do you mean, and to when?"
      }
    }

    private func present(
      _ d: EditDecision, id: String,
      candidates: (items: [EditItem], tasks: [String: OneTask], events: [String: OneEvent])
    ) {
      if let event = candidates.events[id] {
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
        lastTouched = event.title
        change = PendingChange(
          subject: .event(event), delete: d.op == .delete, title: event.title,
          oldText: plannerDayLabel(event.start, runtime: runtime), newStart: d.newStart,
          notes: notes,
          attendees: audience?.attendees ?? 0)
      } else if let task = candidates.tasks[id] {
        var notes: [String] = []
        if d.op == .move {
          notes.append(
            "Only this reminder's date changes.")
          if task.ringsAsAlarm { notes.append("Its alarm follows the new time.") }
        }
        lastTouched = task.title
        change = PendingChange(
          subject: .task(task), delete: d.op == .delete, title: task.title,
          oldText: task.due.map { plannerDayLabel($0, runtime: runtime) }
            ?? "No date", newStart: d.newStart, notes: notes,
          attendees: 0)
      } else {
        return
      }
      messages.append(reply("Here's the change. Nothing changes until you apply it."))
      recordCard(shown: "change", items: 1)
    }

    private func apply(_ c: PendingChange) {
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

    private func show(_ feedback: AskActionFeedback, card: String) {
      messages.append(contentsOf: feedback.messages)
      if let undo = feedback.undo { offerUndo(undo.label, card: card, undo.action) }
    }

    /// The app's toast sits behind this full-screen page, so Undo lives here.
    private func offerUndo(_ label: String, card: String, _ action: @escaping () -> Void) {
      undoRow = UndoRow(
        label: label,
        action: {
          activity.record(ActivityEvents.aiUndo(card: card, thread: threadID))
          withAnimation(reduceMotion ? nil : .default) { action() }
        })
    }

    /// One item per line: rules own scheduling, followed by kind classification and title-only refinement.
    /// A line that lists several things goes to the multi-item model path when it is available.
    private func propose(_ text: String, history: String = "") {
      if ChatRouting.hasMultipleActions(text) {
        proposeList(text, history: history)
      } else {
        understand(text, history: history)
      }
    }

    /// A list needs separate previews; failed extraction asks for separate messages instead of collapsing actions.
    private func proposeList(_ text: String, history: String) {
      guard intelligence.isAvailable() else {
        messages.append(
          reply(
            "Please send one item at a time while the AI service is unavailable. Nothing has been added."
          ))
        return
      }
      thinking = true
      traceBackend(generationToken, modelPath: true)
      let token = generationToken
      captureTask = Task { @MainActor in
        defer { finishEmission(token) }
        let proposed = await intelligence.propose(text, history, now(), runtime.calendar)
        guard !Task.isCancelled, !AIResponseTrace.enabled || token == generationToken else {
          return
        }
        thinking = false
        guard let proposed, proposed.count >= 2 else {
          messages.append(
            reply(
              "I couldn't separate those items. Please send them one at a time. Nothing has been added."
            ))
          return
        }
        show(proposed)
      }
    }

    /// The Send tap is the scoped approval for a clear one-off reminder. Save errors leave
    /// the same card open; Added/Undo/Open come only from the normal commit receipt.
    private func createSubmittedReminder(_ capture: Capture) {
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

    private func show(_ captures: [Capture], note: String? = nil) {
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
    private func filed(_ capture: Capture) -> Capture {
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

    // MARK: Agent (flag today.ai.agent, docs/engineering/ai-agent-architecture.md P2)

    private var agentEnabled: Bool { Preferences.aiAgentEnabled(presentation.defaults) }

    private func agentSession() -> AskAgentSession {
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
    private func runAgent(typed: String, text: String, anchor: UUID) {
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
        let client = HostedLunaClient()
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
        messages.append(reply(result.reply))
        if result.cards > 0 { recordCard(shown: "agent", items: result.cards) }
      }
    }

    /// Offline, signed out, over quota or a failed request (§4.7 #3): FastLane alone. Tidy keeps working,
    /// a reminder, event or alarm the rules are sure of becomes a preview card (nothing is written until
    /// Add), and anything else says the AI is unavailable and puts the draft back in the composer.
    private func runLocally(_ text: String, typed: String, error: ModelClientError) {
      if OverdueTidy.isRequest(text) {
        recordTurn("tidy", text, route: "offline")
        clearPreviews()
        proposeTidy()
        return
      }
      let chinese = AgentReply.isChinese(typed)
      if let capture = FastLane.localPreview(
        text, items: editCandidates().items, now: now(), calendar: runtime.calendar)
      {
        recordTurn("capture", text, route: "offline")
        clearPreviews()
        show([capture], note: AgentReply.localPreview(error, chinese: chinese))
        if capture.ringsAsAlarm, capture.hour == nil {
          followup = .alarmTime
          messages.append(
            reply(
              chinese
                ? "闹钟要设在几点？确认添加后才会生效。"
                : "What time should the alarm ring? Nothing is added until you confirm."))
        }
        return
      }
      recordTurn("unavailable", text, route: "offline")
      messages.append(reply(AgentReply.unavailable(error, chinese: chinese)))
      if draft.isEmpty { draft = typed }
    }

    /// Text plus card receipts in place of replayable items (§1.5): version change, size, or a rejected replay.
    private func compactAgentHistory(_ session: AskAgentSession) {
      let transcript = messages.dropLast().map { (isUser: $0.role == .user, text: $0.text) }
      let captures = proposals.filter { $0.agentID == nil && $0.status != .open }.map {
        "card “\($0.capture.title)” \($0.status.rawValue)"
      }
      session.tools.history.compact(
        transcript: Array(transcript), receipts: session.tools.receipts + captures, now: now())
      saveAgentHistory()
    }

    private func saveAgentHistory() {
      guard let agent else { return }
      if thread == nil { persist() }
      guard let thread else { return }
      let data = agent.tools.history.encoded
      guard thread.agentItemsData != data else { return }
      thread.agentItemsData = data
      try? context.save()
    }

    /// FastLane's direct reminder goes into the agent's history as a receipt with its item id (§1.5),
    /// so a follow-up like "其实是4点" can find it.
    private func recordFastLaneReceipt(typed: String) {
      guard let p = proposals.last, p.status == .added, let ref = p.itemRef else { return }
      let session = agentSession()
      let id = session.tools.history.shortID(for: Ledger.comparisonKey(ref), prefix: "t")
      let due = p.capture.taskTiming(calendar: runtime.calendar).due
      let when = due.map { plannerDayLabel($0, runtime: runtime) } ?? "no date"
      session.tools.history.appendReceipt(
        user: typed,
        receipt:
          "Receipt from the app (rules, no model): added reminder \(id) “\(p.capture.title)”, due \(when), "
          + "from the user's own words. The user can Undo it on its card.")
      saveAgentHistory()
    }

    @ViewBuilder
    private func agentChanges(under anchor: UUID) -> some View {
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

    // MARK: Cards: Add, Cancel, Undo, Open

    /// The cards under one AI message, grouped by line (a line's items are one card or one list).
    @ViewBuilder
    private func cards(under anchor: UUID) -> some View {
      let batches = proposals.filter { $0.anchor == anchor }.map(\.batch).reduce(into: [UUID]()) {
        if !$0.contains($1) { $0.append($1) }
      }
      ForEach(batches, id: \.self) { batch in
        CaptureStack(
          proposals: batchBinding(batch), lists: lists.map(\.name),
          onAdd: add, onSkip: skip, onAddAll: addAll, onUndo: undo, onOpen: open, onRename: rename
        )
        .id(batch)
        .background { responseProbe(.capture(batch)) }
      }
    }

    private func batchBinding(_ batch: UUID) -> Binding<[CaptureProposal]> {
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
    private func persistCards() {
      guard let thread else { return }
      let decided = proposals.compactMap(\.stored).filter { $0.status != .open || $0.retainsDraft }
      guard thread.cards != decided else { return }
      thread.cards = decided
      thread.updatedAt = now()
      try? context.save()
    }

    private func add(_ id: UUID) {
      commit(id)
    }

    private func addAll() {
      for p in proposals where p.status == .open { commit(p.id) }
    }

    /// Writes one proposal (a card that was undone can be added again) and marks it Added. The card stays; it remembers
    /// what was written so Undo and Open reach exactly that.
    @discardableResult
    private func commit(_ id: UUID) -> Capture? {
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
        messages.append(
          reply(
            "Couldn't save “\(capture.title)”: \(error.localizedDescription) The draft is still here; tap Add to retry."
          ))
        return nil
      }
      recordCard(resolved: "capture", edits.isEmpty ? "applied" : "edited", edits: edits)
      thread?.items.append(written.id)
      lastTouched = capture.title
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
    private func skip(_ id: UUID) {
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
    private func undo(_ id: UUID) {
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
    private func open(_ id: UUID) {
      guard let p = proposals.first(where: { $0.id == id }) else { return }
      switch CaptureUndo.resolve(p.itemRef, in: context) {
      case .task(let task): onOpenTask(task, refreshCardTitles)
      case .alarm(let alarm): onOpenAlarm(alarm, refreshCardTitles)
      case .event(let event): onOpenDay(event.start)
      case nil: messages.append(reply("“\(p.capture.title)” isn't there any more."))
      }
    }

    /// Save changes the existing item, then every card in this chat that refers to it.
    private func rename(_ id: UUID, to title: String) -> Bool {
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

    private func refreshCardTitles() {
      for i in proposals.indices where proposals[i].status == .added {
        if let title = actions.captureTitle(proposals[i].itemRef, in: context) {
          proposals[i].capture.title = title
        }
      }
      persistCards()
    }

    private func isOverdue(_ task: OneTask) -> Bool {
      !task.isDone && (task.due.map { $0 < runtime.calendar.startOfDay(for: now()) } ?? false)
    }

    /// Suggests a new date for every overdue reminder (see `OverdueTidy`). Nothing changes until Apply.
    private func proposeTidy() {
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
      let n = tidy.count
      recordCard(shown: "tidy", items: n)
      messages.append(
        reply(
          "\(n) overdue reminder\(n == 1 ? "" : "s"). Flagged and recent ones first, three a day; "
            + "ones older than a month lose their date but stay in their list. Change any row, then Apply. Nothing changes until you do."
        ))
    }

    private func applyTidy() {
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

    private var todaySummary: String {
      let cal = runtime.calendar
      let now = now()
      let open = tasks.filter { task in
        guard !task.isDone else { return false }
        if isOverdue(task) { return true }
        if let d = task.due, cal.isDate(d, inSameDayAs: now) { return true }
        return false
      }
      let todayEvents = events.compactMap { e in
        askOccurrences(e, on: now, calendar: cal).first { $0 > now }.map { (e, $0) }
      }
      var lines = [
        "Today: \(open.count) open task\(open.count == 1 ? "" : "s") and \(todayEvents.count) upcoming event\(todayEvents.count == 1 ? "" : "s")."
      ]
      lines += open.prefix(5).map { "· " + $0.title }
      lines += todayEvents.prefix(3).map {
        "· " + askTimeLabel($0.1, runtime: runtime) + " " + $0.0.title
      }
      return lines.joined(separator: "\n")
    }
  }

  /// User messages are bubbles on the right; AI replies are plain text, no bubble. Text can be selected
  /// (long-press), and a small copy button sits under each message, as in ChatGPT.
  package struct MessageView: View {
    package let message: ChatMessage
    @State private var copied = false

    package var body: some View {
      switch message.role {
      case .user:
        VStack(alignment: .trailing, spacing: 4) {
          HStack {
            Spacer(minLength: 48)
            Text(message.text)
              .textSelection(.enabled)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 20))
          }
          copyButton
        }
      case .ai:
        VStack(alignment: .leading, spacing: 4) {
          Text(message.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          // The app's own status sentences ("Here's what I understood…", "Updated…") have nothing worth copying.
          if !message.isTemplate { copyButton }
        }
      }
    }

    private var copyButton: some View {
      Button {
        UIPasteboard.general.string = message.text
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .sensoryFeedback(.success, trigger: copied) { _, new in new }
      .accessibilityLabel(copied ? "Copied" : "Copy message")
      .accessibilityIdentifier("message.copy")
    }

    package init(message: ChatMessage) { self.message = message }
  }

  /// One overdue reminder on the tidy card, with the date the user picked for it.
  package struct TidyRow: Identifiable {
    package let id = UUID()
    package let task: OneTask
    package let oldDue: Date
    package var choice: OverdueTidy.Choice

    package init(task: OneTask, oldDue: Date, choice: OverdueTidy.Choice) {
      self.task = task
      self.oldDue = oldDue
      self.choice = choice
    }
  }

  /// "Tidy overdue" preview: a suggested date per reminder, each changeable from its menu; Apply writes them all.
  package struct TidyCard: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Binding package var rows: [TidyRow]
    package var onApply: () -> Void
    package var onCancel: () -> Void

    package var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label("New dates for overdue", systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        ViewThatFits(in: .vertical) {
          list
          ScrollView { list }
        }
        .frame(maxHeight: 240)
        HStack {
          Button("Cancel", action: onCancel).buttonStyle(.bordered)
          Spacer()
          Button(action: onApply) {
            Text("Apply").foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
          .disabled(rows.allSatisfy { $0.choice == .keep })
          .accessibilityIdentifier("tidy.apply")
        }
        .padding(.top, 4)
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var list: some View {
      VStack(spacing: 6) {
        ForEach($rows) { $row in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
              Text(row.task.title).font(.subheadline).lineLimit(1)
              Text("was " + plannerDayLabel(row.oldDue, runtime: presentation.runtime)).font(
                .caption
              ).foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            Menu {
              Picker("New date", selection: $row.choice) {
                ForEach(OverdueTidy.choices(repeats: row.task.repeats != nil)) {
                  Text($0.rawValue).tag($0)
                }
              }
            } label: {
              HStack(spacing: 4) {
                Text(row.choice.rawValue)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
              }
              .font(.subheadline)
              .foregroundStyle(row.choice == .keep ? Color.secondary : Color.accentColor)
            }
            .accessibilityIdentifier("tidy.choice.\(row.task.title)")
            .accessibilityValue(row.choice.rawValue)
          }
        }
      }
    }

    package init(
      rows: Binding<[TidyRow]>, onApply: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
      _rows = rows
      self.onApply = onApply
      self.onCancel = onCancel
    }
  }

  /// An AI edit waiting for Apply: what changes and who it reaches. Nothing has been written yet.
  package struct PendingChange: Equatable, Identifiable {
    package enum Subject {
      case task(OneTask)
      case event(OneEvent)
      case alarm(OneAlarm)
      case systemEvent
    }
    package let id = UUID()
    package let subject: Subject
    package let delete: Bool
    package let title: String
    package let oldText: String
    package var newStart: Date?
    package let notes: [String]
    package let attendees: Int
    package var newRepeatRule: String?
    package var expectedTask: TaskSnapshot?
    package var attachedOperation: AttachedItemEdit.Operation?
    package var alarmChange: AttachedAlarmChange?
    package var systemMove: CalendarMoveSnapshot?

    package static func == (a: PendingChange, b: PendingChange) -> Bool { a.id == b.id }

    /// The write this card stands for; nil for subjects Ask applies elsewhere (alarms, Apple Calendar).
    @MainActor
    package var proposal: ChangeProposal? {
      let target: ChangeProposal.Target
      switch subject {
      case .task(let task): target = .task(task)
      case .event(let event): target = .event(event)
      case .alarm, .systemEvent: return nil
      }
      let edit: ChangeProposal.Edit?
      if delete {
        edit = .delete
      } else if case .task = subject, let rule = newRepeatRule, let due = newStart {
        edit = .setRepeat(rule: rule, due: due)
      } else if let newStart {
        edit = .move(newStart)
      } else {
        edit = nil
      }
      var expected: ProposalSnapshot?
      if case .task = subject { expected = expectedTask.map(ProposalSnapshot.init(task:)) }
      return ChangeProposal(
        target: target, edit: edit, oldText: oldText, attendees: attendees, expected: expected)
    }

    package var isEvent: Bool {
      switch subject {
      case .event, .systemEvent: true
      default: false
      }
    }

    package init(
      subject: Subject, delete: Bool, title: String, oldText: String,
      newStart: Date?, notes: [String], attendees: Int
    ) {
      self.subject = subject
      self.delete = delete
      self.title = title
      self.oldText = oldText
      self.newStart = newStart
      self.notes = notes
      self.attendees = attendees
    }
  }

  package struct UndoRow: Identifiable {
    package let id = UUID()
    package let label: String
    package let action: () -> Void

    package init(label: String, action: @escaping () -> Void) {
      self.label = label
      self.action = action
    }
  }

  /// AI change preview: old → new, who is affected, applied only on tap.
  package struct ChangeCard: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    package let change: PendingChange
    package var onApply: () -> Void
    package var onCancel: () -> Void

    package var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(heading, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(change.title).font(.headline)
        if change.delete {
          Text(change.oldText).font(.subheadline).foregroundStyle(.secondary)
        } else if case .rename(let name)? = change.attachedOperation {
          Text("\(change.title) → \(name)").font(.subheadline)
        } else if case .done? = change.attachedOperation {
          Text("Mark completed").font(.subheadline)
        } else if let new = change.newStart {
          Text("\(change.oldText) → \(plannerDayLabel(new, runtime: presentation.runtime))")
            .font(.subheadline)
            .accessibilityIdentifier("change-times")
        }
        ForEach(change.notes, id: \.self) { note in
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Cancel", action: onCancel).buttonStyle(.bordered)
          Spacer()
          Button(action: onApply) {
            Text(change.delete ? "Delete" : "Apply")
              .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(.top, 4)
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("change-card")
    }

    private var heading: String {
      if change.attachedOperation != nil { return "Change item" }
      if change.newRepeatRule != nil { return "Change reminder" }
      switch (change.delete, change.isEvent) {
      case (false, false): return "Move task"
      case (false, true): return "Move event"
      case (true, false): return "Delete task"
      case (true, true): return "Delete event"
      }
    }

    package init(
      change: PendingChange, onApply: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
      self.change = change
      self.onApply = onApply
      self.onCancel = onCancel
    }
  }

  /// The items a "which one?" question offers. Each is a real item from the calendar or task list; tapping one answers the question.
  struct ChoiceBar: View {
    @Environment(PlannerPresentation.self) private var presentation
    let options: [AskView.ChoiceOption]
    var onPick: (AskView.ChoiceOption) -> Void

    var body: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(options) { option in
            Button {
              onPick(option)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(option.title).font(.subheadline).lineLimit(1)
                if let when = option.when {
                  Text(plannerDayLabel(when, runtime: presentation.runtime)).font(.caption)
                    .foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressScale())
            .tint(.primary)
            .accessibilityIdentifier("ask-choice")
          }
        }
        .padding(.horizontal, 2)
      }
    }
  }

  /// Native mutation feedback shared by Ask and deterministic scenes. Call Undo through the caller's Activity/UI host.
  @MainActor
  package struct AskActionFeedback {
    package var messages: [ChatMessage] = []
    package var undo: UndoRow?
    package var applied = true
  }

  /// Real approved Ask mutations. These functions never run while a proposal is merely being prepared.
  @MainActor
  package enum AskNativeActions {
    package static func applyChange(
      _ c: PendingChange, context: ModelContext, calendar: any CalendarService,
      actions: PlannerActions, ledger: Ledger, runtime: PlannerRuntime
    ) -> AskActionFeedback {
      guard let proposal = c.proposal else {
        var feedback = AskActionFeedback()
        feedback.applied = false
        return feedback
      }
      return feedback(
        ToolRegistry.apply(
          proposal, context: context, calendar: calendar, actions: actions, ledger: ledger),
        runtime: runtime)
    }

    /// A user-approved move of one Apple Calendar occurrence. `report` posts replies that arrive later (Undo).
    /// `moved` is the verified result, so the caller can point its attached subject at it.
    package static func applySystemMove(
      _ snapshot: CalendarMoveSnapshot, to start: Date, context: ModelContext,
      calendar: any CalendarService, ledger: Ledger, runtime: PlannerRuntime,
      report: @escaping (ChatMessage) -> Void
    ) -> (feedback: AskActionFeedback, moved: CalendarMoveSnapshot?) {
      let outcome = ToolRegistry.apply(
        SystemMoveProposal(expected: snapshot, start: start), context: context,
        calendar: calendar, ledger: ledger,
        report: { report(ChatMessage(role: .ai, text: $0, timestamp: runtime.now())) })
      return (feedback(outcome.result, runtime: runtime), outcome.moved)
    }

    package static func applyTidy(
      rows: inout [TidyRow], context: ModelContext, actions: PlannerActions, ledger: Ledger,
      runtime: PlannerRuntime
    ) -> AskActionFeedback {
      let proposal = TidyProposal(
        rows: rows.map {
          TidyProposal.Row(task: $0.task, expectedDue: $0.oldDue, choice: $0.choice)
        }
      )
      let result = ToolRegistry.apply(
        proposal, context: context, actions: actions, ledger: ledger, runtime: runtime)
      if result.applied { rows = [] }
      return feedback(result, runtime: runtime)
    }

    private static func feedback(_ result: WriteResult, runtime: PlannerRuntime)
      -> AskActionFeedback
    {
      var feedback = AskActionFeedback()
      feedback.applied = result.applied
      feedback.messages = result.replies.map {
        ChatMessage(role: .ai, text: $0, timestamp: runtime.now())
      }
      feedback.undo = result.undo.map { UndoRow(label: $0.label, action: $0.run) }
      return feedback
    }
  }

  func askTimeLabel(_ date: Date, runtime: PlannerRuntime) -> String {
    let formatter = DateFormatter()
    formatter.calendar = runtime.calendar
    formatter.timeZone = runtime.calendar.timeZone
    formatter.locale = runtime.locale
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  /// Explicit-calendar projection while One's persistent model helpers retain compatibility defaults.
  func askOccurrences(_ event: OneEvent, on day: Date, calendar: Calendar) -> [Date] {
    guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
    return Recurrence.occurrences(
      start: event.start, duration: event.duration, rule: event.repeats, in: interval,
      calendar: calendar)
  }
#endif

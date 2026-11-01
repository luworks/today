#if os(iOS)
  import EventKit
  import SwiftData
  import SwiftUI
  import Testing
  import TodayCore
  import TodayDesignSystem
  import TodayTestSupport
  import UIKit
  import Vision
  @testable import FeatureAsk
  @testable import One

  @MainActor
  @Suite(.serialized)
  struct AskInteractionTests {
    @Test
    func pastedNewlinesStayDraftUntilExplicitSubmission() async throws {
      let fixture = try AskFixture()
      defer { fixture.dispose() }
      try fixture.open()
      try await Task.sleep(for: .milliseconds(500))
      let input = try #require(fixture.input)
      UIPasteboard.general.string = "Remind me to call Alex tomorrow at 3pm\n"
      (input as? UIResponder)?.paste(nil)
      #expect(await fixture.waitForInput("Remind me to call Alex tomorrow at 3pm\n"))
      #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<OneTask>()) == 0)
      #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 0)
      #expect(fixture.inputText.contains("call Alex"))
      let editor = try #require(input as? any UITextInput)
      let all = try #require(
        editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument))
      do {
        editor.selectedTextRange = all
        UIPasteboard.general.string = "First line\nSecond line\n"
        (input as? UIResponder)?.paste(nil)
        #expect(await fixture.waitForInput("First line\nSecond line\n"))
        #expect(fixture.inputText == "First line\nSecond line\n")
        #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 0)
        editor.selectedTextRange = editor.textRange(
          from: editor.endOfDocument, to: editor.endOfDocument)
        UIPasteboard.general.string = "\n"
        (input as? UIResponder)?.paste(nil)
        #expect(await fixture.waitForInput("First line\nSecond line\n\n"))
        #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 0)
        editor.selectedTextRange = editor.textRange(
          from: editor.beginningOfDocument, to: editor.endOfDocument)
        editor.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0))
        let native = try #require(input as? UITextView)
        #expect(native.markedTextRange != nil)
        #expect(
          native.delegate?.textView?(
            native,
            shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n") == true)
        editor.unmarkText()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<ChatThread>()) == 0)
      }
      print(
        "ASK_INPUT pasteAndSyntheticMarkedText tasks=\(try fixture.container.mainContext.fetchCount(FetchDescriptor<OneTask>())) draft=\(fixture.inputText.count)"
      )
    }

    @Test
    func suggestionRenderingDoesNotReadCalendarUntilLifecycleRefresh() async throws {
      let fixture = try AskFixture()
      defer { fixture.dispose() }
      var reads = 0
      var stores = 0
      var eventTitle = "Fixture review meeting"
      fixture.defaults.set(true, forKey: "one.calendarSync.enabled")
      let source = CalendarSync(
        defaults: fixture.defaults, runtime: fixture.runtime, arguments: [],
        makeStore: {
          stores += 1
          return EKEventStore()
        },
        readEvents: { interval in
          reads += 1
          let start = fixture.runtime.now().addingTimeInterval(3600)
          guard interval.contains(start) else { return [] }
          return [
            ExternalEvent(
              id: "ask-occurrence", eventIdentifier: "ask-event",
              title: eventTitle, start: start, end: start.addingTimeInterval(1800),
              isAllDay: false, calendarID: "ask-calendar", calendarTitle: "Fixture", color: .blue)
          ]
        }, authorizationStatus: { .fullAccess })
      defer { source.dispose() }
      let list = AskSuggestionList(
        calendar: source, now: fixture.runtime.now,
        presentation: fixture.presentation, travel: fixture.services.travel,
        activity: fixture.services.activity, intelligence: fixture.intelligence,
        memory: fixture.memory, onSend: { _ in }
      )
      // Evaluate the body itself. ImageRenderer also runs lifecycle tasks, so its total reads
      // cannot distinguish a render-time read from an explicitly scheduled lifecycle read.
      _ = list.body
      print("ASK_SUGGESTIONS body rangeReads=\(reads)")
      #expect(reads == 0, "Evaluating body must not query Calendar")
      let host = UIHostingController(rootView: list.modelContainer(fixture.container))
      host.loadViewIfNeeded()
      host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
      host.view.layoutIfNeeded()
      try fixture.show(host)
      try await Task.sleep(for: .milliseconds(200))
      #expect(reads > 0, "The lifecycle must still prepare suggestions")
      #expect(try await fixture.waitForLabel(eventTitle))
      let initial = reads
      #expect(initial == 2, "One accepted snapshot reads today and tomorrow once each")
      host.view.setNeedsLayout()
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      #expect(reads == initial)
      eventTitle = "Refreshed review meeting"
      source.refresh()
      try await Task.sleep(for: .milliseconds(200))
      #expect(reads == initial + 2, "Calendar version changes must refresh each day exactly once")
      #expect(try await fixture.waitForLabel(eventTitle))
      let refreshed = reads
      await source.setEnabled(false)
      try await Task.sleep(for: .milliseconds(100))
      #expect(reads == refreshed, "Disabling Calendar must not read its retired source")
      #expect(try await fixture.waitForLabel(eventTitle, present: false))
      #expect(stores == 0, "The injected scalar source must never open EventKit")
      print("ASK_SUGGESTIONS lifecycle=\(initial) refreshed=\(refreshed) disabled=\(reads)")
    }
  }

  @MainActor
  private final class AskFixture {
    let suite = "AskInteraction.\(UUID())"
    let defaults: UserDefaults
    let container: ModelContainer
    let runtime = PlannerRuntime(
      now: { Date(timeIntervalSince1970: 1_792_314_000) }, nextID: { UUID() },
      calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
    let services: PlannerTestServices
    let presentation: PlannerPresentation
    let memory = AskSuggestionMemory()
    var window: UIWindow?
    var previous: UIWindow?
    var host: UIViewController?
    var intelligence: AskIntelligence {
      AskIntelligence(
        backend: { .scripted },
        parse: { text, _, now, calendar in CaptureParser.parse(text, now: now, calendar: calendar)
        },
        propose: { _, _, _, _ in nil }, refineTitle: { capture, _, _ in capture },
        respond: { _, _, _ in
          return .reply("Delayed fixture reply")
        }, plan: { _, _, _, _, _ in EditPlan(op: .none, target: nil) },
        rank: { _, _, _, _ in nil }, prewarm: {}, isAvailable: { true },
        unavailableReason: { _ in nil })
    }
    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, Habit.self,
        ChatThread.self, LedgerEntry.self, AIGrant.self, ShareImportReceipt.self,
      ])
      container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
      services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime, arguments: [])
      presentation = PlannerPresentation(runtime: runtime, defaults: defaults)
    }
    func open(thread: ChatThread? = nil) throws {
      let view = AskView(
        thread: thread, calendar: services.calendar, now: runtime.now,
        actions: services.actions, ledger: services.ledger, activity: services.activity,
        intelligence: intelligence, agentModel: .unavailable,
        voice: VoiceInput(driver: LiveSpeechInputDriver(locale: runtime.locale)),
        presentation: presentation, travel: services.travel, suggestionMemory: memory,
        onBack: { _ in }, onAdded: { _ in }, onOpenDay: { _ in },
        onOpenTask: { _, _ in }, onOpenAlarm: { _, _ in }
      )
      .modelContainer(container)
      try show(UIHostingController(rootView: view))
    }
    func show(_ controller: UIViewController) throws {
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      previous = scene.windows.first(where: \.isKeyWindow)
      let w = UIWindow(windowScene: scene)
      w.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
      w.rootViewController = controller
      host = controller
      window = w
      w.makeKeyAndVisible()
    }
    var views: [UIView] {
      func children(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(children) }
      return host.map { children($0.view) } ?? []
    }
    var input: (any UIKeyInput)? {
      views.first(where: { $0 is UITextField || $0 is UITextView }) as? any UIKeyInput
    }
    var inputText: String {
      if let field = input as? UITextField { return field.text ?? "" }
      return (input as? UITextView)?.text ?? ""
    }
    func waitForInput(_ text: String) async -> Bool {
      for _ in 0..<100 {
        if inputText == text { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return false
    }
    func waitForLabel(_ text: String, present: Bool = true) async throws -> Bool {
      for _ in 0..<20 {
        let visible = try labels()
        if visible.contains(text) == present { return true }
        try await Task.sleep(for: .milliseconds(100))
      }
      print("ASK_SUGGESTIONS visible=\(try labels()) expected=\(text)")
      return false
    }
    func labels() throws -> String {
      let controller = try #require(host)
      controller.view.layoutIfNeeded()
      let data =
        UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
          controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }.pngData() ?? Data()
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(data: data).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: " ")
    }
    func dispose() {
      window?.endEditing(true)
      window?.isHidden = true
      window?.rootViewController = nil
      host = nil
      previous?.makeKey()
      memory.dispose()
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
    }
  }
#endif

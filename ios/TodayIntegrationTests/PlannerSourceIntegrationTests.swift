#if os(iOS)
  import Foundation
  import SwiftData
  import EventKit
  import Testing
  import TodayCore
  import TodayData
  import TodayShared
  import TodayTestSupport
  import TodayDesignSystem
  import TodayPlatform
  import TodayPlannerUI
  import FeatureToday
  import FeatureHealth
  import SwiftUI
  import UIKit
  import Vision
  @testable import One

  /// Real model/action integration with local service spies; no EventKit store is opened.
  @MainActor
  extension PlannerSessionTests {
    @Test
    func calendarGrantPrecedesStatusUpdateWithoutOverridingRevocation() async throws {
      let a = try SourceSession()
      defer { a.dispose() }
      var status = EKAuthorizationStatus.notDetermined
      var granted = true
      var fails = false
      var requests = 0
      var nativeStores = 0
      let calendar = CalendarSync(
        defaults: a.defaults, runtime: a.services.runtime, arguments: [],
        makeStore: {
          nativeStores += 1
          return EKEventStore()
        }, authorizationStatus: { status },
        requestFullAccess: {
          requests += 1
          if fails { throw CocoaError(.userCancelled) }
          return granted
        })
      defer { calendar.dispose() }
      #expect(!calendar.hasAccess && !calendar.isOn)
      await calendar.setEnabled(true)
      #expect(requests == 1 && calendar.hasAccess && calendar.isOn)
      #expect(a.defaults.bool(forKey: "one.calendarSync.enabled"))
      status = .denied
      #expect(!calendar.hasAccess && !calendar.isOn)
      status = .notDetermined
      #expect(!calendar.hasAccess, "A determined denial retires the earlier callback")
      for denied in [EKAuthorizationStatus.denied, .restricted, .writeOnly] {
        status = denied
        await calendar.setEnabled(true)
        #expect(!calendar.hasAccess && !calendar.isOn)
      }
      status = .notDetermined
      granted = false
      await calendar.setEnabled(true)
      #expect(!calendar.hasAccess && !calendar.enabled)
      granted = true
      fails = true
      await calendar.setEnabled(true)
      #expect(!calendar.hasAccess && !calendar.enabled)
      fails = false
      await calendar.setEnabled(true)
      #expect(calendar.isOn)
      status = .fullAccess
      #expect(calendar.isOn)
      status = .notDetermined
      #expect(!calendar.hasAccess, "A later unknown state cannot reuse a settled grant")
      await calendar.setEnabled(true)
      await calendar.setEnabled(false)
      #expect(!calendar.hasAccess && !calendar.isOn)
      #expect(nativeStores == 0)
    }

    @Test
    func populatedDayAgendaRenderNeverOpensTheNativeStore() async throws {
      let a = try SourceSession()
      defer { a.dispose() }
      let runtime = a.services.runtime
      let today = runtime.calendar.startOfDay(for: a.now)
      a.defaults.set(true, forKey: "today.remindersSync.enabled")
      a.defaults.set(true, forKey: "one.calendarSync.enabled")
      a.defaults.set(false, forKey: SettingsKey.healthSummary)
      a.defaults.set(false, forKey: SettingsKey.jumpToNow)
      a.defaults.set(false, forKey: Preferences.showFreeTimeKey)
      var nativeStoreCreations = 0
      var rangeReads = 0
      let reminder = OneTask(title: "Rendered imported Reminder")
      reminder.externalID = "rendered-reminder"
      reminder.due = today.addingTimeInterval(9 * 3600)
      a.context.insert(reminder)
      try a.context.save()
      let remote = RemindersSync.Remote(
        id: "rendered-reminder", title: reminder.title, notes: "", isDone: false, doneAt: nil,
        due: nil, listID: "fixture-list", listTitle: "Fixture", flagged: false,
        repeatRule: nil, repeats: false, accountID: "fixture-account")
      let reminderSync = RemindersSync(
        defaults: a.defaults, runtime: runtime, arguments: [],
        makeStore: {
          nativeStoreCreations += 1
          return EKEventStore()
        },
        authorizationStatus: { .fullAccess })
      reminderSync.acceptFocusSnapshot([remote])
      let eventID = FocusIdentity(
        provider: "apple.calendar", account: "fixture-account", calendar: "fixture-calendar",
        item: "rendered-event")
      let event = ExternalEvent(
        id: "rendered-event", eventIdentifier: "rendered-event",
        title: "Rendered imported Calendar",
        start: today, end: today.addingTimeInterval(86400), isAllDay: true,
        calendarID: eventID.calendar, calendarTitle: "Fixture", color: .blue)
      let calendar = CalendarSync(
        defaults: a.defaults, runtime: runtime, arguments: [],
        makeStore: {
          nativeStoreCreations += 1
          return EKEventStore()
        },
        readEvents: { interval in
          rangeReads += 1
          return event.start < interval.end && event.end > interval.start ? [event] : []
        }, authorizationStatus: { .fullAccess })
      defer {
        reminderSync.dispose()
        calendar.dispose()
      }
      calendar.acceptFocusSnapshot(event, identity: eventID, canDelete: true)
      let actions = PlannerActions(
        calendar: calendar, reminders: reminderSync, alarms: a.services.alarms,
        ledger: a.services.ledger, runtime: runtime)
      let presentation = PlannerPresentation(runtime: runtime, defaults: a.defaults)
      let health = HealthLineModel(
        model: HealthModel(
          source: MockHealthSource(), store: HealthSelectionStore(defaults: a.defaults),
          runtime: runtime, gate: HealthAccessGate()))
      let view = DayAgenda(
        day: .constant(a.now), showsWeekStrip: false, openTask: { _ in }, openEvent: { _ in },
        openAlarm: { _ in }, openTimer: {}, actions: actions, calendar: calendar,
        timers: a.services.timers, reminders: reminderSync, ledger: a.services.ledger,
        travel: a.services.travel, presentation: presentation
      )
      .modelContainer(a.context.container)
      .environment(presentation).environment(health).environment(WeatherModel())
      .environment(\.calendar, runtime.calendar).environment(\.locale, runtime.locale)
      .environment(\.timeZone, runtime.calendar.timeZone)
      let host = UIHostingController(rootView: view)
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 393, height: 1000)
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
      }
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      window.layoutIfNeeded()
      #expect(host.view.bounds.width > 0 && host.view.bounds.height > 0)
      var drawn = false
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      #expect(drawn, "The real populated DayAgenda window must render successfully")
      Attachment.record(try #require(image.pngData()), named: "populated-day-agenda.png")
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([request])
      let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ").lowercased()
      #expect(
        labels.contains(reminder.title.lowercased()),
        "The actual rendered pixels must contain the imported Reminder: \(labels)")
      #expect(
        labels.contains(event.title.lowercased()),
        "The actual rendered pixels must contain the imported Calendar: \(labels)")
      #expect(reminderSync.isConnected && calendar.isOn && calendar.isReady)
      #expect(rangeReads > 0)
      #expect(reminderSync.focusIdentity(reminder) == .available(remote.focusIdentity!))
      #expect(calendar.cachedCanDelete(externalID: event.eventIdentifier))
      #expect(
        nativeStoreCreations == 0, "Mounted Today rows and their menus must never open EventKit")
    }

    @Test
    func calendarDeletionKeepsUnavailableOrChangedMirrorsAndLocalSeriesUndo() throws {
      let a = try SourceSession()
      defer { a.dispose() }
      let event = OneEvent(title: "Fixed source event", start: a.now, durationMinutes: 60)
      event.externalID = "source-event"
      a.context.insert(event)
      try a.context.save()
      let entry = CalEntry(
        id: "entry", source: .local(event), title: event.title,
        start: event.start, end: event.start.addingTimeInterval(3600), isAllDay: false, color: .blue
      )
      for resolution in [FocusIdentityResolution.unavailable, .permissionDenied] {
        a.services.calendar.focusResolutions["source-event"] = resolution
        a.services.actions.delete(entry, span: .futureEvents, context: a.context, toast: a.toast)
        #expect(!event.isDeleted && event.modelContext != nil)
        #expect(event.externalID == "source-event" && event.start == a.now)
        #expect(a.services.calendar.deletionRequests.isEmpty && !a.toast.canUndo)
      }
      a.services.calendar.focusResolutions["source-event"] = .available(
        FocusIdentity(
          provider: "apple.calendar", account: "source", calendar: "calendar", item: "source-event")
      )
      a.services.calendar.deletionResult = false
      a.services.actions.delete(entry, span: .futureEvents, context: a.context, toast: a.toast)
      #expect(!event.isDeleted && event.modelContext != nil && !a.toast.canUndo)
      #expect(a.services.calendar.deletionRequests == ["source-event"])
      a.context.delete(event)
      try a.context.save()

      // Purely local series still have exact local Undo; no source series is recreated.
      let series = OneEvent(title: "Local series", start: a.now, durationMinutes: 30)
      series.repeatRule = "daily"
      series.note = "Retain local metadata"
      a.context.insert(series)
      try a.context.save()
      let seriesEntry = CalEntry(
        id: "series", source: .local(series), title: series.title,
        start: series.start, end: series.start.addingTimeInterval(1800), isAllDay: false,
        color: .blue, repeats: true)
      a.services.actions.delete(seriesEntry, span: .thisEvent, context: a.context, toast: a.toast)
      #expect(try a.context.fetchCount(FetchDescriptor<OneEvent>()) == 1)
      #expect(a.services.calendar.deletionRequests == ["source-event"] && !a.toast.canUndo)
      a.services.actions.delete(
        seriesEntry, span: .futureEvents, context: a.context, toast: a.toast)
      #expect(try a.context.fetchCount(FetchDescriptor<OneEvent>()) == 0)
      #expect(a.toast.canUndo)
      a.toast.performUndo()
      let restored = try #require(a.context.fetch(FetchDescriptor<OneEvent>()).first)
      #expect(restored.title == "Local series" && restored.repeatRule == "daily")
      #expect(restored.start == a.now && restored.note == "Retain local metadata")
      #expect(
        restored.externalID == nil && a.services.calendar.deletionRequests == ["source-event"])
    }

    @Test
    func deleteAllLocalDataKeepsTheAppleSource() throws {
      let a = try SourceSession()
      defer { a.dispose() }
      _ = try a.addTask()
      a.services.reminders.hasAccess = true
      a.services.reminders.isConnected = true

      DataReset.run(
        a.context, reminders: a.services.reminders, ledger: a.services.ledger,
        inbox: EmptyInbox())

      #expect(try a.context.fetchCount(FetchDescriptor<OneTask>()) == 0)
      #expect(try a.services.activityStore.count() == 0)
      #expect(!a.services.reminders.isConnected && !a.services.reminders.hasAccess)
      a.expectNoSourceWrites()
    }
  }

  @MainActor
  private struct EmptyInbox: ShareInboxReading {
    func read() throws -> [SharedReminder] { [] }
    func acknowledge(_ ids: Set<UUID>) -> Bool { true }
  }

  @MainActor
  private final class SourceSession {
    let suite = "PlannerSourceIntegrationTests.\(UUID().uuidString)"
    let directory: URL
    let defaults: UserDefaults
    let now = Date(timeIntervalSince1970: 1_792_314_000)
    let context: ModelContext
    let services: PlannerTestServices
    let toast = UndoToast()

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      defaults.removePersistentDomain(forName: suite)
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let instant = now
      let runtime = PlannerRuntime(
        now: { instant }, nextID: { UUID() }, calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX"))
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, Habit.self,
        ChatThread.self, LedgerEntry.self, AIGrant.self, ShareImportReceipt.self,
      ])
      let container = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
      context = ModelContext(container)
      context.autosaveEnabled = false
      services = try PlannerTestServices(
        container: container, defaults: defaults,
        runtime: runtime, arguments: [],
        activityStore: nil)
    }

    func addTask() throws -> OneTask {
      let task = OneTask(
        title: "Source reminder", note: "Original note", due: now.addingTimeInterval(3600))
      task.externalID = "reminder-fixture"
      task.repeatRule = "weekly:1"
      task.listName = "Source list"
      task.flagged = true
      context.insert(task)
      try context.save()
      services.reminders.focusResolutions["reminder-fixture"] = .available(
        FocusIdentity(
          provider: "apple.reminders", account: "account", calendar: "list",
          item: "stable-reminder"))
      return task
    }

    func expectNoSourceWrites() {
      #expect(services.reminders.completionCalls.isEmpty)
      #expect(services.reminders.persistedCompletions.isEmpty)
      #expect(services.reminders.editCalls == 0)
      #expect(services.reminders.deletedReminderIDs.isEmpty)
      #expect(services.reminders.deletedListIDs.isEmpty)
      #expect(services.reminders.reconcileDelays.isEmpty && services.reminders.reconcileCount == 0)
      #expect(services.alarms.syncCount == 0 && services.alarms.stoppedIDs.isEmpty)
      #expect(services.calendar.refreshCount == 0)
    }

    func dispose() {
      toast.dispose()
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }
#endif

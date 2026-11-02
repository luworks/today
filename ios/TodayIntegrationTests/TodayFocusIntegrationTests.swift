#if os(iOS)
  import Foundation
  import Synchronization
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
    func settleDayBoundaryReleasesSameSourcesAndCrossDayUndoWithoutSourceWrites() throws {
      let a = try FocusSession(persistentFocus: true)
      defer { a.dispose() }
      let task = try a.addTask()
      let payload = Ledger.snapshot(of: task)
      let calendar = a.services.runtime.calendar
      let midnight = calendar.date(
        byAdding: .day, value: 1,
        to: calendar.startOfDay(for: a.now))!
      let clock = Mutex(midnight.addingTimeInterval(-60))
      let runtime = PlannerRuntime(
        now: { clock.withLock { $0 } }, nextID: { UUID() },
        calendar: calendar, locale: a.services.runtime.locale)
      func makeFocus() -> TodayFocus {
        TodayFocus(ledger: a.services.ledger, runtime: runtime)
      }
      let focus = makeFocus()
      let reminder = try #require(a.reminderIdentity(task))
      let event = OneEvent(title: "Yesterday fixed event", start: a.now, durationMinutes: 30)
      a.context.insert(event)
      try a.context.save()
      let sourceStart = event.start
      let eventID = FocusIdentity(
        provider: "today.local", account: "local-store",
        calendar: "event", item: "stable-event", occurrence: event.start)
      for identity in [reminder, eventID] {
        #expect(
          focus.change(
            .settled, identity: identity, localReference: nil,
            title: "Synthetic source", context: a.context, toast: nil))
        #expect(focus.state(for: identity, now: runtime.now()) == .settled)
      }
      // Unsettle on D, then Undo on D+1 must not renew yesterday's decision.
      #expect(
        focus.change(
          .active, identity: reminder, localReference: nil,
          title: task.title, context: a.context, toast: a.toast))
      clock.withLock { $0 = midnight }
      #expect(
        runtime.refreshedTodayDay(
          a.now, previousNow: midnight.addingTimeInterval(-60),
          now: runtime.now()) == midnight)
      let browsed = calendar.date(byAdding: .day, value: -3, to: a.now)!
      #expect(runtime.refreshedTodayDay(browsed, previousNow: a.now, now: midnight) == browsed)
      a.toast.performUndo()
      for projection in [focus, makeFocus()] {
        #expect(projection.state(for: reminder, now: runtime.now()) == nil)
        #expect(projection.state(for: eventID, now: runtime.now()) == nil)
      }
      #expect(event.occurs(on: midnight, calendar: calendar).isEmpty)
      #expect(plannerIsOverdue(task, now: midnight, calendar: calendar))
      #expect(Ledger.snapshot(of: task) == payload)
      #expect(event.start == sourceStart && event.repeatRule == nil)
      // Same series, next occurrence cannot inherit yesterday's settled identity.
      event.repeatRule = "daily"
      let next = try #require(event.occurs(on: midnight, calendar: calendar).first)
      let nextID = FocusIdentity(
        provider: eventID.provider, account: eventID.account,
        calendar: eventID.calendar, item: eventID.item, occurrence: next)
      #expect(focus.state(for: nextID, now: runtime.now()) == nil)
      a.expectNoSourceWrites()
    }

    @Test
    func focusLifecyclePreservesSourcePayloadThroughProductionAdapters() async throws {
      let a = try FocusSession(persistentFocus: true)
      defer { a.dispose() }
      let task = try a.addTask()
      task.tags = ["source-tag"]
      task.checklist = [ChecklistItem(title: "Unfinished source step")]
      task.reminderOffsetMinutes = 17
      task.ringsAsAlarm = true
      let event = OneEvent(title: "Source series", start: a.now, durationMinutes: 47)
      event.note = "Original event note"
      event.calendarName = "Source calendar"
      event.externalID = "event-fixture"
      event.repeatRule = "daily"
      event.reminderOffsetMinutes = 23
      event.ringsAsAlarm = true
      a.context.insert(event)
      try a.context.save()
      let taskID = task.persistentModelID
      let eventID = event.persistentModelID
      let taskPayload = Ledger.snapshot(of: task)
      // Every persisted event field, including identity and alert configuration.
      func eventPayload() throws -> Data {
        try JSONSerialization.data(
          withJSONObject: [
            "title": event.title, "note": event.note,
            "start": event.start.timeIntervalSince1970,
            "duration": event.durationMinutes, "calendar": event.calendarName,
            "alert": event.reminderOffsetMinutes as Any? ?? NSNull(),
            "allDay": event.isAllDay, "rings": event.ringsAsAlarm,
            "externalID": event.externalID as Any? ?? NSNull(),
            "repeat": event.repeatRule as Any? ?? NSNull(),
          ], options: [.sortedKeys])
      }
      let originalEvent = try eventPayload()
      let occurrences = event.occurrences(in: DateInterval(start: a.now, duration: 3 * 86400))
      a.defaults.set(true, forKey: "today.remindersSync.enabled")
      a.defaults.set(true, forKey: "today.calendarSync.enabled")
      var nativeStoreCalls = 0
      let reminders = RemindersSync(
        defaults: a.defaults, runtime: a.services.runtime, arguments: [],
        makeStore: {
          nativeStoreCalls += 1
          return EKEventStore()
        },
        authorizationStatus: { .fullAccess })
      let calendar = CalendarSync(
        defaults: a.defaults, runtime: a.services.runtime, arguments: [],
        makeStore: {
          nativeStoreCalls += 1
          return EKEventStore()
        },
        loadFocus: { _ in [] }, authorizationStatus: { .fullAccess })
      defer {
        reminders.dispose()
        calendar.dispose()
      }
      let remote = RemindersSync.Remote(
        id: "reminder-fixture", title: task.title, notes: task.note, isDone: false,
        doneAt: nil, due: task.due, listID: "list", listTitle: task.listName,
        flagged: true, repeatRule: task.repeatRule, repeats: true, accountID: "account")
      let reminderIdentity = try #require(remote.focusIdentity)
      let calendarIdentity = FocusIdentity(
        provider: "apple.calendar", account: "account", calendar: "calendar",
        item: "series", occurrence: event.start)
      let imported = ExternalEvent(
        id: "selected-occurrence", eventIdentifier: "event-fixture", title: event.title,
        start: event.start, end: event.start.addingTimeInterval(event.duration),
        isAllDay: false, calendarTitle: event.calendarName, color: .blue, repeats: true)
      func acceptImport() {
        reminders.acceptFocusSnapshot([remote])
        calendar.acceptFocusSnapshot(imported, identity: calendarIdentity, canDelete: true)
      }
      func makeActions() -> PlannerActions {
        PlannerActions(
          calendar: calendar, reminders: reminders, alarms: a.services.alarms,
          ledger: a.services.ledger, runtime: a.services.runtime)
      }
      func expectUnchanged() throws {
        #expect(Ledger.snapshot(of: task) == taskPayload)
        #expect(task.externalID == remote.id && task.persistentModelID == taskID)
        #expect(try eventPayload() == originalEvent)
        #expect(event.persistentModelID == eventID)
        #expect(
          event.occurrences(in: DateInterval(start: a.now, duration: 3 * 86400)) == occurrences)
        #expect(try a.context.fetchCount(FetchDescriptor<OneTask>()) == 1)
        #expect(try a.context.fetchCount(FetchDescriptor<OneEvent>()) == 1)
        // Any native save/remove path must first obtain the adapter's lazy EventKit store.
        #expect(nativeStoreCalls == 0)
        a.expectNoSourceWrites()
        #expect(a.services.calendar.deletionRequests.isEmpty)
        #expect(a.services.alarms.scheduledIDs.isEmpty && a.services.alarms.cancelledIDs.isEmpty)
        #expect(a.services.notifications.resyncCount == 0)
      }
      acceptImport()
      var actions = makeActions()
      let until = a.now.addingTimeInterval(3600)
      for (identity, reference) in [
        (reminderIdentity, TodayFocus.reference(taskID)),
        (calendarIdentity, TodayFocus.reference(eventID)),
      ] {
        for state in [TodayFocusState.settled, .active, .snoozed(until: until), .active] {
          let previous = actions.focus.state(for: identity, now: a.now)
          #expect(
            actions.focus.change(
              state, identity: identity, localReference: reference, title: "Synthetic source",
              context: a.context, toast: a.toast))
          #expect(
            actions.focus.state(for: identity, now: a.now) == (state == .active ? nil : state))
          try expectUnchanged()
          a.toast.performUndo()
          #expect(actions.focus.state(for: identity, now: a.now) == previous)
          try expectUnchanged()
          #expect(
            actions.focus.change(
              state, identity: identity, localReference: reference, title: "Synthetic source",
              context: a.context, toast: nil))
        }
        #expect(
          actions.focus.change(
            .snoozed(until: until), identity: identity, localReference: reference,
            title: "Synthetic source", context: a.context, toast: nil))
      }
      let records = actions.focus.records
      calendar.refresh()
      acceptImport()
      actions = makeActions()  // Reopens the production disk overlay, without reseeding sources.
      await calendar.hydrateFocus(actions.focus.records)
      #expect(actions.focus.records == records)
      for identity in [reminderIdentity, calendarIdentity] {
        #expect(actions.focus.state(for: identity, now: until.addingTimeInterval(-1)) != nil)
        #expect(actions.focus.state(for: identity, now: until) == nil)
        #expect(actions.focus.records == records, "Expiry only changes read-time classification")
      }
      #expect(reminders.focusIdentity(task) == .available(reminderIdentity))
      #expect(
        calendar.cachedEvent(externalID: "event-fixture", occurrence: event.start) == imported)
      #expect(
        actions.focus.state(
          for: FocusIdentity(
            provider: calendarIdentity.provider, account: calendarIdentity.account,
            calendar: calendarIdentity.calendar, item: calendarIdentity.item,
            occurrence: event.start.addingTimeInterval(86400)), now: a.now) == nil)
      try expectUnchanged()
      // A concurrent disk change must keep the existing row classification and source intact.
      let file = a.directory.appendingPathComponent("activity.focus-v1.json")
      var bytes = try Data(contentsOf: file)
      bytes.append(0x0A)
      try bytes.write(to: file, options: .atomic)
      let revision = actions.focus.revision
      #expect(
        !actions.focus.change(
          .settled, identity: reminderIdentity, localReference: TodayFocus.reference(taskID),
          title: task.title, context: a.context, toast: a.toast))
      #expect(actions.focus.revision == revision && actions.focus.records == records)
      #expect(a.toast.message?.contains("Couldn't save") == true)
      #expect(try Data(contentsOf: file) == bytes)
      try expectUnchanged()
    }

    @Test
    func savedCalendarSnoozeHydratesOutsideOriginalDayAndRejectsStaleImports() async throws {
      let suite = "FocusHydration.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(true, forKey: "today.calendarSync.enabled")
      let original = Date(timeIntervalSince1970: 1_792_314_000)
      let tomorrow = original.addingTimeInterval(86400)
      let identity = FocusIdentity(
        provider: "apple.calendar", account: "account", calendar: "calendar",
        item: "series", occurrence: original)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let location = TodayFocusStore.Location.file(directory.appendingPathComponent("focus.json"))
      try TodayFocusStore(location: location).set(
        state: .snoozed(until: tomorrow), for: identity, now: original,
        localReference: "eventkit:exact-event")
      let reopened = try TodayFocusStore(location: location)
      let records = reopened.records
      let imported = CalendarFocusImport(
        externalID: "exact-event", identity: identity, title: "Current source title",
        start: original, end: original.addingTimeInterval(1800), isAllDay: false,
        calendarTitle: "Fixture", colorComponents: [0, 0, 1], repeats: true, canDelete: true)
      let loader = FocusImportFixture(row: imported)
      var access = EKAuthorizationStatus.fullAccess
      var nativeCalls = 0
      let calendar = CalendarSync(
        defaults: defaults,
        runtime: PlannerRuntime(
          now: { tomorrow }, nextID: { UUID() }, calendar: Calendar(identifier: .gregorian),
          locale: Locale(identifier: "en_US_POSIX")), arguments: [],
        makeStore: {
          nativeCalls += 1
          return EKEventStore()
        },
        loadFocus: { await loader.load($0) }, authorizationStatus: { access })
      defer { calendar.dispose() }
      #expect(imported.end < tomorrow)  // Tomorrow's range cannot populate this occurrence.
      #expect(calendar.cachedEvent(externalID: "exact-event", occurrence: original) == nil)
      await calendar.hydrateFocus(records)
      #expect(await loader.requests == [records])
      #expect(reopened.state(for: identity, now: tomorrow) == nil)
      for _ in 0..<1000 {
        #expect(
          calendar.cachedFocusIdentity(externalID: "exact-event", occurrence: original)
            == .available(identity))
        let event = try #require(
          calendar.cachedFocusEvent(identity: identity, reference: records.first?.localReference))
        #expect(event.title == "Current source title" && event.eventIdentifier == "exact-event")
        #expect(event.start == identity.occurrence)  // The Open route uses this exact occurrence.
        #expect(calendar.cachedEvent(externalID: "exact-event", occurrence: tomorrow) == nil)
      }
      #expect(nativeCalls == 0)
      #expect(await loader.requests.count == 1)
      #expect(reopened.records == records)
      calendar.refresh()
      #expect(calendar.cachedEvent(externalID: "exact-event", occurrence: original) == nil)
      await calendar.hydrateFocus(records)
      #expect(
        calendar.cachedFocusIdentity(externalID: "exact-event", occurrence: original)
          == .available(identity))

      // In-flight work cannot publish after a version change, permission loss or cancellation.
      for interruption in 0..<3 {
        calendar.refresh()
        await loader.pause()
        let task = Task { await calendar.hydrateFocus(records) }
        while !(await loader.waiting) { await Task.yield() }
        if interruption == 0 { calendar.refresh() }
        if interruption == 1 { access = .denied }
        if interruption == 2 { task.cancel() }
        await loader.resume()
        await task.value
        #expect(calendar.cachedEvent(externalID: "exact-event", occurrence: original) == nil)
        access = .fullAccess
      }
      // Exact source/account/calendar/item/occurrence must all match; no replacement is adopted.
      for replacement in [
        FocusIdentity(
          provider: "apple.calendar", account: "other", calendar: "calendar",
          item: "series", occurrence: original),
        FocusIdentity(
          provider: "apple.calendar", account: "account", calendar: "other",
          item: "series", occurrence: original),
        FocusIdentity(
          provider: "apple.calendar", account: "account", calendar: "calendar",
          item: "replacement", occurrence: original),
        FocusIdentity(
          provider: "apple.calendar", account: "account", calendar: "calendar",
          item: "series", occurrence: tomorrow),
      ] {
        await calendar.hydrateFocus([
          FocusRecord(
            identity: replacement, state: .settled, changedAt: original,
            localReference: "eventkit:exact-event")
        ])
        #expect(calendar.cachedEvent(externalID: "exact-event", occurrence: original) == nil)
      }
      await loader.setRows([])
      await calendar.hydrateFocus(records)
      #expect(
        calendar.cachedFocusEvent(identity: identity, reference: records.first?.localReference)
          == nil)
      #expect(reopened.records == records && nativeCalls == 0)
    }

    @Test
    func importedFocusRenderingNeverOpensNativeStoreAndWritesStillRevalidate() throws {
      let suite = "FocusRenderCache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(true, forKey: "today.remindersSync.enabled")
      defaults.set(true, forKey: "today.calendarSync.enabled")
      let now = Date(timeIntervalSince1970: 1_792_314_000)
      let runtime = PlannerRuntime(
        now: { now }, nextID: { UUID() }, calendar: Calendar(identifier: .gregorian),
        locale: Locale(identifier: "en_US_POSIX"))
      var access = EKAuthorizationStatus.fullAccess
      var nativeStoreCalls = 0
      // An unavailable native backend must never be consulted for any display lookup, including misses.
      let reminders = RemindersSync(
        defaults: defaults, runtime: runtime, arguments: [],
        makeStore: {
          nativeStoreCalls += 1
          return EKEventStore()
        },
        authorizationStatus: { access })
      let calendar = CalendarSync(
        defaults: defaults, runtime: runtime, arguments: [],
        makeStore: {
          nativeStoreCalls += 1
          return EKEventStore()
        },
        authorizationStatus: { access })
      defer {
        reminders.dispose()
        calendar.dispose()
      }
      let task = OneTask(title: "Synthetic imported reminder")
      task.externalID = "native-reminder"
      task.due = now
      let remote = RemindersSync.Remote(
        id: "native-reminder", title: task.title, notes: "", isDone: false, doneAt: nil,
        due: now, listID: "native-list", listTitle: "Fixture", flagged: false,
        repeatRule: nil, repeats: true, accountID: "native-account")
      let reminderID = try #require(remote.focusIdentity)
      #expect(reminders.focusIdentity(task) == .unavailable)
      reminders.acceptFocusSnapshot([remote])
      let eventID = FocusIdentity(
        provider: "apple.calendar", account: "native-account", calendar: "native-calendar",
        item: "native-event", occurrence: now)
      let event = ExternalEvent(
        id: "fixture-occurrence", eventIdentifier: "native-event", title: "Synthetic event",
        start: now, end: now.addingTimeInterval(1800), isAllDay: false,
        calendarTitle: "Fixture", color: .blue, repeats: true)
      calendar.acceptFocusSnapshot(event, identity: eventID, canDelete: true)
      let start = ContinuousClock.now
      for _ in 0..<1000 {
        #expect(reminders.focusIdentity(task) == .available(reminderID))
        #expect(
          calendar.cachedFocusIdentity(externalID: "native-event", occurrence: now)
            == .available(eventID))
        #expect(calendar.cachedEvent(externalID: "native-event", occurrence: now)?.id == event.id)
        #expect(calendar.cachedCanDelete(externalID: "native-event"))
        #expect(
          calendar.cachedFocusIdentity(externalID: "unknown", occurrence: now) == .unavailable)
        #expect(!calendar.cachedCanDelete(externalID: "unknown"))
      }
      #expect(start.duration(to: .now) < .seconds(2))
      #expect(nativeStoreCalls == 0)
      access = .denied
      #expect(reminders.focusIdentity(task) == .permissionDenied)
      #expect(
        calendar.cachedFocusIdentity(externalID: "native-event", occurrence: now)
          == .permissionDenied)
      #expect(!calendar.cachedCanDelete(externalID: "native-event"))
      // Even a previously writable cached identity cannot authorize a source write after access changes.
      #expect(throws: (any Error).self) {
        try reminders.commitDeletion(task, expected: Ledger.snapshot(of: task))
      }
      #expect(!calendar.delete(externalID: "native-event", occurrence: now, span: .thisEvent))
      #expect(nativeStoreCalls == 0)
      access = .fullAccess
      #expect(reminders.focusIdentity(task) == .available(reminderID))
      #expect(
        calendar.cachedFocusIdentity(
          externalID: "native-event", occurrence: now.addingTimeInterval(86400)) == .unavailable)
      calendar.refresh()
      #expect(
        calendar.cachedFocusIdentity(externalID: "native-event", occurrence: now) == .unavailable)
      #expect(!calendar.cachedCanDelete(externalID: "native-event"))
      reminders.acceptFocusSnapshot([])
      #expect(reminders.focusIdentity(task) == .unavailable)
      #expect(nativeStoreCalls == 0)
    }

    @Test
    func focusPausedOrDisabledActivityDoesNotOwnFocusOrItsUndo() async throws {
      for paused in [true, false] {
        let a = try FocusSession()
        defer { a.dispose() }
        let task = try a.addTask()
        let original = Ledger.snapshot(of: task)
        let originalID = task.persistentModelID
        let identity = a.reminderIdentity(task)
        a.defaults.set(paused, forKey: ActivitySettings.pausedKey)
        a.defaults.set(paused, forKey: ActivitySettings.tierKey(.changes))
        #expect(!a.services.activity.recordsChanges)

        #expect(
          a.services.actions.focus.change(
            .settled, identity: identity, localReference: TodayFocus.reference(originalID),
            title: task.title, context: a.context, toast: a.toast))
        a.services.ledger.flush(a.context)
        #expect(try a.services.activityStore.count() == 0)
        #expect(a.toast.canUndo)
        let records = a.services.actions.focus.records

        // Pruning actually removes an expired Activity row while leaving the independent overlay.
        try a.services.activityStore.insert([
          ActivityEvent(
            kind: "change.settled", actor: "you",
            at: a.now.addingTimeInterval(-800 * 86400))
        ])
        a.services.activity.prune()
        #expect(try a.services.activityStore.count() == 0)
        #expect(a.services.actions.focus.records == records)
        try a.services.activityStore.insert([
          ActivityEvent(kind: "change.settled", actor: "you", at: a.now)
        ])
        #expect(try a.services.activityStore.count() == 1)
        a.services.activity.clear(context: a.context)
        #expect(try a.services.activityStore.count() == 0)
        for format in ActivityExportFormat.allCases {
          let url = a.directory.appendingPathComponent("activity.\(format.fileExtension)")
          let exported = try await a.services.activity.export(format, to: url)
          #expect(FileManager.default.fileExists(atPath: exported.path))
          #expect(a.services.actions.focus.records == records)
        }
        #expect(Ledger.snapshot(of: task) == original)
        #expect(task.persistentModelID == originalID && task.externalID == "reminder-fixture")

        a.toast.performUndo()
        #expect(a.services.actions.focus.state(for: identity, now: a.now) == nil)
        #expect(a.services.actions.focus.records.isEmpty && !a.toast.canUndo)
        #expect(Ledger.snapshot(of: task) == original)
        #expect(try a.context.fetchCount(FetchDescriptor<OneTask>()) == 1)
        #expect(
          a.services.actions.focus.change(
            .settled, identity: identity,
            localReference: TodayFocus.reference(originalID), title: task.title,
            context: a.context, toast: a.toast))
        #expect(
          a.services.actions.focus.change(
            .active, identity: identity,
            localReference: TodayFocus.reference(originalID), title: task.title,
            context: a.context, toast: a.toast))
        #expect(a.services.actions.focus.state(for: identity, now: a.now) == nil)
        #expect(a.services.actions.focus.records.first?.state == .active)
        a.toast.performUndo()
        #expect(a.services.actions.focus.state(for: identity, now: a.now) == .settled)
        #expect(Ledger.snapshot(of: task) == original)
        a.expectNoSourceWrites()
      }
    }

    @Test
    func focusRefreshedSourceFieldsKeepFocusButDifferentIdentityDoesNotInheritIt() throws {
      let a = try FocusSession()
      defer { a.dispose() }
      let task = try a.addTask()
      let reference = try #require(TodayFocus.reference(task.persistentModelID))
      let identity = try #require(a.reminderIdentity(task))
      #expect(
        a.services.actions.focus.change(
          .settled, identity: identity, localReference: reference, title: task.title,
          context: a.context, toast: nil))

      // A source refresh can change content, deadline and completion without changing identity.
      task.title = "Changed in Apple Reminders"
      task.note = "Refreshed source note"
      task.due = a.now.addingTimeInterval(7200)
      task.isDone = true
      task.doneAt = a.now
      try a.context.save()
      #expect(a.reminderIdentity(task) == identity)
      #expect(a.services.actions.focus.state(for: a.reminderIdentity(task), now: a.now) == .settled)

      for resolution in [FocusIdentityResolution.permissionDenied, .unavailable] {
        a.services.reminders.focusResolutions["reminder-fixture"] = resolution
        #expect(a.reminderIdentity(task) == identity)
        #expect(
          a.services.actions.focus.state(for: a.reminderIdentity(task), now: a.now) == .settled)
      }
      for changed in [
        FocusIdentity(
          provider: identity.provider, account: "another-account",
          calendar: identity.calendar, item: identity.item),
        FocusIdentity(
          provider: identity.provider, account: identity.account,
          calendar: "another-list", item: identity.item),
        FocusIdentity(
          provider: identity.provider, account: identity.account,
          calendar: identity.calendar, item: "replacement-reminder"),
        FocusIdentity(
          provider: identity.provider, account: identity.account,
          calendar: identity.calendar, item: identity.item, occurrence: a.now),
      ] {
        a.services.reminders.focusResolutions["reminder-fixture"] = .available(changed)
        #expect(a.reminderIdentity(task) == changed)
        #expect(a.services.actions.focus.state(for: a.reminderIdentity(task), now: a.now) == nil)
        // After an actual identity mismatch, permission interruption cannot reuse the old A anchor.
        a.services.reminders.focusResolutions["reminder-fixture"] = .permissionDenied
        #expect(a.reminderIdentity(task) == nil)
        #expect(a.services.actions.focus.state(for: a.reminderIdentity(task), now: a.now) == nil)
      }
      a.services.reminders.focusResolutions["reminder-fixture"] = .notFound
      #expect(a.reminderIdentity(task) == nil)
      #expect(a.services.actions.focus.state(for: a.reminderIdentity(task), now: a.now) == nil)
      #expect(
        !a.services.actions.focus.change(
          .settled, identity: a.reminderIdentity(task), localReference: reference,
          title: task.title, context: a.context, toast: nil))
      #expect(a.services.actions.focus.records.count == 1)
      #expect(task.isDone && task.doneAt == a.now && task.title == "Changed in Apple Reminders")
      a.expectNoSourceWrites()
    }

    @Test
    func recurringEventFocusAppliesOnlyToSelectedOccurrence() throws {
      let a = try FocusSession()
      defer { a.dispose() }
      let event = OneEvent(title: "Weekly rehearsal", start: a.now, durationMinutes: 45)
      event.externalID = "recurring-event-fixture"
      event.repeatRule = "weekly:1"
      a.context.insert(event)
      try a.context.save()
      let reference = TodayFocus.reference(event.persistentModelID)
      let next = a.now.addingTimeInterval(7 * 86400)
      func resolve(_ occurrence: Date) -> FocusIdentity? {
        let identity = FocusIdentity(
          provider: "apple.calendar", account: "account",
          calendar: "calendar", item: "series", occurrence: occurrence)
        a.services.calendar.focusResolutions["recurring-event-fixture"] = .available(identity)
        return a.services.actions.focus.identity(
          resolution: a.services.calendar.focusIdentity(
            externalID: event.externalID,
            occurrence: occurrence), localReference: reference, kind: "event",
          occurrence: occurrence)
      }
      let selected = try #require(resolve(a.now))
      let other = try #require(resolve(next))
      let until = a.now.addingTimeInterval(3600)
      #expect(
        a.services.actions.focus.change(
          .snoozed(until: until), identity: selected, localReference: reference,
          title: event.title, context: a.context, toast: a.toast))
      #expect(a.services.actions.focus.state(for: selected, now: a.now) == .snoozed(until: until))
      #expect(a.services.actions.focus.state(for: other, now: a.now) == nil)
      #expect(a.services.actions.focus.state(for: selected, now: until) == nil)
      a.toast.performUndo()
      #expect(a.services.actions.focus.state(for: selected, now: a.now) == nil)
      #expect(event.start == a.now && event.durationMinutes == 45)
      #expect(event.repeatRule == "weekly:1" && event.externalID == "recurring-event-fixture")
      #expect(try a.context.fetchCount(FetchDescriptor<OneEvent>()) == 1)
      a.expectNoSourceWrites()
    }

    @Test
    func deleteAllLocalDataClearsFocusWithoutDeletingItsAppleSource() throws {
      let a = try FocusSession()
      defer { a.dispose() }
      let task = try a.addTask()
      let identity = try #require(a.reminderIdentity(task))
      a.services.reminders.hasAccess = true
      a.services.reminders.isConnected = true
      #expect(
        a.services.actions.focus.change(
          .settled, identity: identity,
          localReference: TodayFocus.reference(task.persistentModelID), title: task.title,
          context: a.context, toast: nil))
      #expect(a.services.actions.focus.records.count == 1)

      #expect(
        DataReset.run(
          a.context, reminders: a.services.reminders,
          ledger: a.services.ledger, inbox: EmptyFocusInbox(), focus: a.services.actions.focus))

      #expect(a.services.actions.focus.records.isEmpty)
      #expect(a.services.actions.focus.state(for: identity, now: a.now) == nil)
      #expect(try a.context.fetchCount(FetchDescriptor<OneTask>()) == 0)
      #expect(try a.services.activityStore.count() == 0)
      #expect(!a.services.reminders.isConnected && !a.services.reminders.hasAccess)
      a.expectNoSourceWrites()
    }
  }

  private actor FocusImportFixture {
    var rows: [CalendarFocusImport]
    var requests: [[FocusRecord]] = []
    var waiting = false
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(row: CalendarFocusImport) { rows = [row] }
    func setRows(_ rows: [CalendarFocusImport]) { self.rows = rows }
    func pause() { paused = true }
    func resume() {
      paused = false
      continuation?.resume()
      continuation = nil
      waiting = false
    }
    func load(_ records: [FocusRecord]) async -> [CalendarFocusImport] {
      requests.append(records)
      if paused {
        await withCheckedContinuation {
          continuation = $0
          waiting = true
        }
      }
      return rows
    }
  }

  @MainActor
  private struct EmptyFocusInbox: ShareInboxReading {
    func read() throws -> [SharedReminder] { [] }
    func acknowledge(_ ids: Set<UUID>) -> Bool { true }
  }

  @MainActor
  private final class FocusSession {
    let suite = "TodayFocusIntegrationTests.\(UUID().uuidString)"
    let directory: URL
    let defaults: UserDefaults
    let now = Date(timeIntervalSince1970: 1_792_314_000)
    let context: ModelContext
    let services: PlannerTestServices
    let toast = UndoToast()

    init(persistentFocus: Bool = false) throws {
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
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self,
        ChatThread.self, ShareImportReceipt.self,
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
        activityStore: persistentFocus
          ? ActivityStore(location: .file(directory.appendingPathComponent("activity.sqlite")))
          : nil)
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

    func reminderIdentity(_ task: OneTask) -> FocusIdentity? {
      services.actions.focus.identity(
        resolution: services.reminders.focusIdentity(task),
        localReference: TodayFocus.reference(task.persistentModelID), kind: "task", occurrence: nil)
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

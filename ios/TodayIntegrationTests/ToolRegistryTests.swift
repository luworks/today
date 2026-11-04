#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayCore
  import TodayData
  import TodayTestSupport
  @testable import One

  /// Re-validation in the code-owned write layer (docs/engineering/ai-agent-architecture.md §4.2).
  /// Ask's own writes are pinned by `AskWriteSnapshotTests`.
  @MainActor
  @Suite(.serialized)
  struct ToolRegistryTests {
    @Test
    func aReminderEditWithAStaleExpectationWritesNothing() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Call Sam", due: due)
      let expected = ToolRegistry.snapshot(of: .task(task))
      task.flagged = true
      try a.context.save()
      for edit in [ChangeProposal.Edit.move(due.addingTimeInterval(3600)), .delete] {
        let result = a.apply(
          ChangeProposal(
            target: .task(task), edit: edit, oldText: "", attendees: 0, expected: expected))
        #expect(!result.applied && result.undo == nil)
        #expect(
          result.replies == [
            "This reminder changed since the preview. Ask again to prepare a current preview."
          ])
      }
      #expect(task.due == due && !task.isDeleted)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aReminderEditWithACurrentExpectationApplies() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Call Sam", due: due)
      let result = a.apply(
        ChangeProposal(
          target: .task(task), edit: .move(due.addingTimeInterval(3600)), oldText: "",
          attendees: 0, expected: ToolRegistry.snapshot(of: .task(task))))
      #expect(result.applied && task.due == due.addingTimeInterval(3600))
      #expect(try a.rows().first?.actionValue == .redated)
    }

    @Test
    func aRepeatChangeWithoutAnExpectationIsTreatedAsStale() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Stretch", due: due)
      let result = a.apply(
        ChangeProposal(
          target: .task(task), edit: .setRepeat(rule: "daily", due: due), oldText: "",
          attendees: 0))
      #expect(!result.applied && task.repeatRule == nil)
    }

    @Test
    func anEventEditWithAStaleExpectationWritesNothing() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let event = OneEvent(title: "Review", start: start, durationMinutes: 30)
      a.context.insert(event)
      try a.context.save()
      let expected = ToolRegistry.snapshot(of: .event(event), attendees: 2)
      #expect(expected.start == start && expected.attendees == 2 && !expected.repeats)
      event.start = start.addingTimeInterval(600)
      try a.context.save()
      let result = a.apply(
        ChangeProposal(
          target: .event(event), edit: .move(start.addingTimeInterval(3600)), oldText: "",
          attendees: 2, expected: expected))
      #expect(!result.applied && event.start == start.addingTimeInterval(600))
      #expect(
        result.replies == [
          "This event changed since the preview. Ask again to prepare a current preview."
        ])
      #expect(try a.rows().isEmpty)
    }

    @Test
    func manualReminderMoveCommitsSourceAndUndoRejectsLaterChanges() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let task = a.task("Call Sam", due: original)
      a.services.reminders.isConnected = true
      task.externalID = "reminder-1"
      task.listName = "Work"
      task.flagged = true
      try a.context.save()
      let receipt = try a.services.actions.applyAttachedReminder(
        .move(original.addingTimeInterval(1800)), task: task,
        expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      #expect(a.services.reminders.editCalls == 1)
      #expect(task.listName == "Work" && task.flagged && !task.isDone)
      try receipt.undo()
      #expect(task.due == original && a.services.reminders.editCalls == 2)
      #expect(throws: (any Error).self) { try receipt.undo() }
      let next = try a.services.actions.applyAttachedReminder(
        .move(original.addingTimeInterval(900)), task: task,
        expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      task.title = "Changed elsewhere"
      try a.context.save()
      #expect(throws: (any Error).self) { try next.undo() }
      #expect(task.title == "Changed elsewhere" && task.due == original.addingTimeInterval(900))
    }

    @Test
    func manualReminderFailureDoesNotChangeLocalDue() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let task = a.task("Review", due: original)
      a.services.reminders.isConnected = true
      task.externalID = "reminder-1"
      try a.context.save()
      a.services.reminders.editFailure = .injected
      #expect(throws: (any Error).self) {
        try a.services.actions.applyAttachedReminder(
          .move(original.addingTimeInterval(900)), task: task,
          expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      }
      #expect(task.due == original && !task.isDone)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func manualAlarmMoveSchedulesSameIdentityAndRestoresSettings() async throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let target = a.now.addingTimeInterval(7200)
      let parts = a.runtime.calendar.dateComponents(
        [.hour, .minute], from: a.now.addingTimeInterval(3600))
      let alarm = OneAlarm(
        hour: try #require(parts.hour), minute: try #require(parts.minute), label: "Wake")
      let originalCreatedAt = a.now.addingTimeInterval(-300)
      alarm.createdAt = originalCreatedAt
      alarm.alarmKitID = UUID()
      a.services.alarms.states[try #require(alarm.alarmKitID)] = .scheduled
      alarm.sound = "tone"
      alarm.snoozeMinutes = 7
      a.context.insert(alarm)
      try a.context.save()
      let before = alarm.activitySnapshot
      let entry = try await a.services.actions.applyAttachedAlarm(
        AttachedAlarmChange(alarm: alarm, edit: .move(target)), context: a.context,
        actor: .you, channel: .app)
      #expect(a.services.alarms.scheduledIDs.last == alarm.alarmKitID)
      #expect(alarm.sound == before.sound && alarm.snoozeMinutes == before.snoozeMinutes)
      let error = await a.services.actions.undo(entry, context: a.context)
      #expect(error == nil && alarm.activitySnapshot == before)
      #expect(a.services.alarms.scheduledIDs.count == 2)
      #expect(alarm.createdAt == originalCreatedAt)
    }

    @Test
    func aReminderChangedInAnotherContextCannotBeMovedFromStaleLocalState() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let task = a.task("Review", due: a.now.addingTimeInterval(3600))
      let before = Ledger.snapshot(of: task)
      let writer = ModelContext(a.context.container)
      let other = try #require(try writer.fetch(FetchDescriptor<OneTask>()).first)
      other.note = "Edited in another window"
      try writer.save()
      #expect(throws: (any Error).self) {
        try a.services.actions.applyAttachedReminder(
          .move(a.now.addingTimeInterval(7200)), task: task, expected: before,
          context: a.context, actor: .you, channel: .app)
      }
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aConnectedCalendarProjectsNativeTimesInsteadOfStaleMirrors() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let old = a.now.addingTimeInterval(3600)
      let moved = old.addingTimeInterval(3600)
      let mirror = OneEvent(title: "Planning", start: old, durationMinutes: 30)
      mirror.externalID = "series"
      a.context.insert(mirror)
      try a.context.save()
      a.services.calendar.enabled = true
      a.services.calendar.hasAccess = true
      a.services.calendar.queryEvents = [
        ExternalEvent(
          id: "detached", eventIdentifier: "detached", title: "Planning",
          start: moved, end: moved.addingTimeInterval(1800), isAllDay: false,
          calendarTitle: "Work", color: .blue)
      ]
      let entries = CalendarEntries.make(
        in: DateInterval(start: a.runtime.calendar.startOfDay(for: a.now), duration: 86400),
        events: [mirror], tasks: [], calendarService: a.services.calendar,
        now: a.now, calendar: a.runtime.calendar)
      #expect(entries.count == 1 && entries.first?.start == moved)
      #expect(mirror.start == old, "Projection does not delete or mutate the retained mirror")
    }

    @Test
    func aLocalSeriesExceptionSurvivesPersistenceWithoutChangingTheSeriesAnchor() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let anchor = a.now.addingTimeInterval(-86400)
      let original = a.now
      let moved = original.addingTimeInterval(3600)
      let event = OneEvent(title: "Daily review", start: anchor, durationMinutes: 30)
      event.repeatRule = "daily"
      event.occurrenceOverrides = [.init(original: original, start: moved)]
      a.context.insert(event)
      try a.context.save()
      let reader = ModelContext(a.context.container)
      let saved = try #require(try reader.fetch(FetchDescriptor<OneEvent>()).first)
      #expect(saved.start == anchor)
      #expect(saved.occurs(on: original, calendar: a.runtime.calendar) == [moved])
      #expect(
        saved.occurs(on: original.addingTimeInterval(86400), calendar: a.runtime.calendar)
          == [original.addingTimeInterval(86400)])
    }

    @Test
    func anAlarmUndoNeverTurnsAnExpiredOriginalRingIntoTomorrow() async throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let parts = a.runtime.calendar.dateComponents(
        [.hour, .minute], from: a.now.addingTimeInterval(7200))
      let old = a.runtime.calendar.dateComponents(
        [.hour, .minute], from: a.now.addingTimeInterval(-3600))
      let alarm = OneAlarm(hour: try #require(parts.hour), minute: try #require(parts.minute))
      alarm.createdAt = a.now
      alarm.alarmKitID = UUID()
      a.services.alarms.states[try #require(alarm.alarmKitID)] = .scheduled
      a.context.insert(alarm)
      try a.context.save()
      let after = alarm.activitySnapshot
      var before = after
      before.hour = try #require(old.hour)
      before.minute = try #require(old.minute)
      var entry = a.services.ledger.record(
        .edited, item: alarm, kind: "alarm", title: "Alarm",
        snapshot: AlarmChange(
          before: before, after: after,
          beforeCreatedAt: a.now.addingTimeInterval(-7200), afterCreatedAt: a.now),
        context: a.context)
      entry.itemRef = Ledger.ref(alarm.persistentModelID)
      let error = await a.services.actions.undo(entry, context: a.context)
      #expect(error?.contains("original alarm time has passed") == true)
      #expect(alarm.activitySnapshot == after && a.services.alarms.scheduledIDs.isEmpty)
    }

    @Test
    func aSystemMoveCommitsOneOccurrenceAndRefusesStaleUndo() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      func snapshot(_ start: Date) -> CalendarMoveSnapshot {
        CalendarMoveSnapshot(
          externalID: "event", calendarID: "work", sourceID: "fixture", itemID: "series",
          occurrence: start, start: start, end: start.addingTimeInterval(1800), isAllDay: false,
          lastModified: start, title: "Planning", location: "Office", notes: "Keep", url: nil,
          audience: CalendarMoveAudience(attendeeCount: 0, isOrganizer: nil), participantIDs: [])
      }
      let before = snapshot(a.now.addingTimeInterval(3600))
      let after = snapshot(before.start.addingTimeInterval(1800))
      var current = before
      var commits = 0
      a.services.calendar.moveEventResult = { expected, requested in
        guard expected == current else { throw CalendarMoveError.stale }
        #expect(requested == after.start)
        commits += 1
        current = after
        return .verified(.init(before: before, after: after))
      }
      a.services.calendar.undoMoveResult = { receipt in
        guard receipt.after == current else { throw CalendarMoveError.stale }
        current = receipt.before
        return .verified
      }
      var reports: [String] = []
      let result = ToolRegistry.apply(
        .init(expected: before, start: after.start), context: a.context,
        calendar: a.services.calendar, ledger: a.services.ledger, actor: .you, channel: .app,
        report: { reports.append($0) })
      #expect(result.moved == after && commits == 1)
      let undo = try #require(result.result.undo)
      current = snapshot(after.start.addingTimeInterval(300))
      undo.run()
      #expect(current.start == after.start.addingTimeInterval(300))
      #expect(reports.last?.contains("Couldn't undo") == true)
    }

    @Test
    func aReadOnlyCalendarFailureNeverProducesSuccessOrUndo() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let before = CalendarMoveSnapshot(
        externalID: "readonly", calendarID: "subscription", sourceID: "fixture",
        itemID: "event", occurrence: start, start: start, end: start.addingTimeInterval(1800),
        isAllDay: false, lastModified: a.now, title: "Read-only", location: nil, notes: nil,
        url: nil,
        audience: CalendarMoveAudience(attendeeCount: 0, isOrganizer: nil), participantIDs: [])
      a.services.calendar.moveEventResult = { _, _ in throw CalendarMoveError.readOnly }
      let result = ToolRegistry.apply(
        .init(expected: before, start: start.addingTimeInterval(300)),
        context: a.context, calendar: a.services.calendar, ledger: a.services.ledger,
        actor: .you, channel: .app, report: { _ in })
      #expect(!result.result.applied && result.result.undo == nil && result.moved == nil)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func activityReminderUndoCommitsSourceAndNeverOverwritesALaterDue() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(900)
      let task = a.task("Review", due: original)
      a.services.reminders.isConnected = true
      task.externalID = "reminder-1"
      try a.context.save()
      _ = try a.services.actions.applyAttachedReminder(
        .move(moved), task: task,
        expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      let entry = try #require(try a.rows().first)
      #expect(a.services.ledger.undo(entry, context: a.context))
      #expect(task.due == original && a.services.reminders.editCalls == 2)
      _ = try a.services.actions.applyAttachedReminder(
        .move(moved), task: task,
        expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      let latest = try #require(
        try a.rows().first(where: { $0.actionValue == .redated && $0.id != entry.id }))
      task.due = moved.addingTimeInterval(300)
      try a.context.save()
      #expect(!a.services.ledger.undo(latest, context: a.context))
      #expect(task.due == moved.addingTimeInterval(300) && a.services.reminders.editCalls == 3)
    }

    @Test
    func activityReminderUndoFailureLeavesTheCurrentDueAndReceiptIntact() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(900)
      let task = a.task("Review", due: original)
      a.services.reminders.isConnected = true
      task.externalID = "reminder-1"
      try a.context.save()
      _ = try a.services.actions.applyAttachedReminder(
        .move(moved), task: task,
        expected: Ledger.snapshot(of: task), context: a.context, actor: .you, channel: .app)
      let entry = try #require(try a.rows().first)
      a.services.reminders.editFailure = .injected
      #expect(!a.services.ledger.undo(entry, context: a.context))
      #expect(task.due == moved && !a.services.ledger.isUndone(entry))
      a.services.reminders.editFailure = nil
      #expect(a.services.ledger.undo(entry, context: a.context))
      #expect(task.due == original)
    }

    @Test
    func alarmMoveUndoStillWorksWhenActivityRecordingIsPaused() async throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      a.defaults.set(true, forKey: ActivitySettings.pausedKey)
      let parts = a.runtime.calendar.dateComponents(
        [.hour, .minute], from: a.now.addingTimeInterval(3600))
      let alarm = OneAlarm(hour: try #require(parts.hour), minute: try #require(parts.minute))
      alarm.createdAt = a.now
      let id = UUID()
      alarm.alarmKitID = id
      a.services.alarms.states[id] = .scheduled
      a.context.insert(alarm)
      try a.context.save()
      let before = alarm.activitySnapshot
      let entry = try await a.services.actions.applyAttachedAlarm(
        AttachedAlarmChange(alarm: alarm, edit: .move(a.now.addingTimeInterval(7200))),
        context: a.context, actor: .you, channel: .app)
      #expect(try a.rows().isEmpty)
      let result = await a.services.actions.undo(entry, context: a.context)
      #expect(result == nil && alarm.activitySnapshot == before)
      #expect(a.services.alarms.scheduledIDs == [id, id])
      #expect(
        try a.rows().isEmpty, "Pause remains respected; the selected Undo receipt is session-only")
      let repeated = await a.services.actions.undo(entry, context: a.context)
      #expect(repeated != nil && a.services.alarms.scheduledIDs.count == 2)
    }

    @Test
    func aTransientCalendarUndoFailureRetainsARetryWithoutRepeatingTheMove() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      func snapshot(_ start: Date) -> CalendarMoveSnapshot {
        CalendarMoveSnapshot(
          externalID: "event", calendarID: "work", sourceID: "fixture", itemID: "event",
          occurrence: start, start: start, end: start.addingTimeInterval(1800), isAllDay: false,
          lastModified: start, title: "Planning", location: nil, notes: nil, url: nil,
          audience: CalendarMoveAudience(attendeeCount: 0, isOrganizer: nil), participantIDs: [])
      }
      let before = snapshot(a.now.addingTimeInterval(3600))
      let after = snapshot(before.start.addingTimeInterval(1800))
      var moves = 0
      var restores = 0
      a.services.calendar.moveEventResult = { _, _ in
        moves += 1
        return .verified(.init(before: before, after: after))
      }
      a.services.calendar.undoMoveResult = { _ in
        restores += 1
        if restores == 1 { throw CalendarMoveError.unavailable }
        return .verified
      }
      let result = ToolRegistry.apply(
        .init(expected: before, start: after.start), context: a.context,
        calendar: a.services.calendar, ledger: a.services.ledger, actor: .you, channel: .app,
        report: { _ in })
      let undo = try #require(result.result.undo)
      undo.run()
      #expect(undo.canRetry?() == true)
      undo.run()
      #expect(undo.canRetry?() == false && moves == 1 && restores == 2)
    }

    @Test
    func anExecutingAlarmCannotBeRescheduledOrMarkedCompleteByAMove() async throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let parts = a.runtime.calendar.dateComponents(
        [.hour, .minute], from: a.now.addingTimeInterval(3600))
      let alarm = OneAlarm(hour: try #require(parts.hour), minute: try #require(parts.minute))
      alarm.createdAt = a.now
      let id = UUID()
      alarm.alarmKitID = id
      a.services.alarms.states[id] = .snoozing
      a.context.insert(alarm)
      try a.context.save()
      let before = alarm.activitySnapshot
      let change = try AttachedAlarmChange(
        alarm: alarm, edit: .move(a.now.addingTimeInterval(7200)))
      do {
        _ = try await a.services.actions.applyAttachedAlarm(
          change, context: a.context, actor: .you, channel: .app)
        Issue.record("An executing alarm must reject a move")
      } catch AttachedAlarmChange.Failure.active {
        // The execution state is protected without changing or completing the alarm.
      }
      #expect(alarm.activitySnapshot == before && a.services.alarms.states[id] == .snoozing)
      #expect(a.services.alarms.scheduledIDs.isEmpty && a.services.alarms.cancelledIDs.isEmpty)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aVerifiedCalendarMoveUpdatesOnlyItsMirrorOccurrenceAndUndoRestoresAlerts() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(1800)
      let event = OneEvent(
        title: "Planning", start: original.addingTimeInterval(-86400), durationMinutes: 30)
      event.externalID = "series"
      event.repeatRule = "daily"
      event.reminderOffsetMinutes = 10
      event.ringsAsAlarm = true
      a.context.insert(event)
      try a.context.save()
      let before = mirrorSnapshot(original, id: "series")
      let after = mirrorSnapshot(moved, id: "detached")
      let movedAgain = moved.addingTimeInterval(300)
      let afterAgain = mirrorSnapshot(movedAgain, id: "detached-again")
      var current = before
      var moves = 0
      var restores = 0
      a.services.calendar.moveEventResult = { expected, start in
        guard expected == current else { throw CalendarMoveError.stale }
        moves += 1
        let target = start == moved ? after : afterAgain
        let receipt = CalendarMoveReceipt(before: current, after: target)
        current = target
        return .verified(receipt)
      }
      a.services.calendar.undoMoveResult = { receipt in
        guard receipt.after == current else { throw CalendarMoveError.stale }
        restores += 1
        current = receipt.before
        return .verified
      }
      a.services.calendar.moveSnapshotResult = { _, _ in current }
      let result = ToolRegistry.apply(
        .init(expected: before, start: moved), context: a.context,
        calendar: a.services.calendar, ledger: a.services.ledger, actor: .you, channel: .app,
        report: { _ in })
      #expect(result.moved == after)
      #expect(event.start == original.addingTimeInterval(-86400) && event.externalID == "series")
      #expect(event.occurs(on: original, calendar: a.runtime.calendar) == [moved])
      #expect(
        event.occurs(on: original.addingTimeInterval(86400), calendar: a.runtime.calendar) == [
          original.addingTimeInterval(86400)
        ])
      #expect(plannerReminderDate(event, runtime: a.runtime) == moved.addingTimeInterval(-600))
      #expect(event.ringsAsAlarm && event.reminderOffsetMinutes == 10)
      let undo = try #require(result.result.undo)
      let second = ToolRegistry.apply(
        .init(expected: after, start: movedAgain), context: a.context,
        calendar: a.services.calendar, ledger: a.services.ledger, report: { _ in })
      #expect(second.moved == afterAgain)
      #expect(event.occurs(on: original, calendar: a.runtime.calendar) == [movedAgain])
      undo.run()
      #expect(restores == 0, "The earlier receipt must not undo the later drag")
      let undoSecond = try #require(second.result.undo)
      undoSecond.run()
      #expect(event.occurs(on: original, calendar: a.runtime.calendar) == [moved])
      undo.run()
      #expect(event.occurrenceOverrides.isEmpty)
      #expect(plannerReminderDate(event, runtime: a.runtime) == original.addingTimeInterval(-600))
      undo.run()
      #expect(moves == 2 && restores == 2, "An already committed Undo never writes twice")
    }

    @Test
    func aCalendarUndoRetryOnlyFinishesTheMirrorAfterTheSourceWasRestored() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(1800)
      let event = OneEvent(title: "Planning", start: original, durationMinutes: 30)
      event.externalID = "event"
      a.context.insert(event)
      try a.context.save()
      let before = mirrorSnapshot(original, id: "event")
      let after = mirrorSnapshot(moved, id: "moved-id")
      let restored = mirrorSnapshot(original, id: "restored-id")
      var restores = 0
      a.services.calendar.moveEventResult = { _, _ in .verified(.init(before: before, after: after))
      }
      a.services.calendar.undoMoveResult = { _ in
        restores += 1
        return .verified
      }
      a.services.calendar.moveSnapshotResult = { _, _ in throw CalendarMoveError.unavailable }
      let result = ToolRegistry.apply(
        .init(expected: before, start: moved), context: a.context,
        calendar: a.services.calendar, ledger: a.services.ledger, report: { _ in })
      let undo = try #require(result.result.undo)
      undo.run()
      #expect(undo.canRetry?() == true && restores == 1)
      #expect(event.start == moved && event.externalID == "moved-id")
      a.services.calendar.moveSnapshotResult = { _, _ in restored }
      undo.run()
      #expect(undo.canRetry?() == false && restores == 1)
      #expect(event.start == original && event.externalID == "restored-id")
    }

    @Test
    func aCalendarMirrorSaveFailureRetainsThePriorTimeAndCanRetry() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(1800)
      let event = OneEvent(title: "Planning", start: original, durationMinutes: 30)
      event.externalID = "event"
      a.context.insert(event)
      try a.context.save()
      let mirrors = try CalendarMoveMirrors(
        expected: mirrorSnapshot(original, id: "event"), context: a.context)
      let receipt = CalendarMoveReceipt(
        before: mirrorSnapshot(original, id: "event"),
        after: mirrorSnapshot(moved, id: "changed-id"))
      #expect(throws: (any Error).self) {
        try mirrors.apply(receipt, save: { throw CocoaError(.fileWriteUnknown) })
      }
      #expect(event.start == original && event.externalID == "event")
      try mirrors.apply(receipt)
      #expect(event.start == moved && event.externalID == "changed-id")
      #expect(throws: (any Error).self) {
        try mirrors.restore(save: { throw CocoaError(.fileWriteUnknown) })
      }
      #expect(event.start == moved && event.externalID == "changed-id")
      try mirrors.restore()
      #expect(event.start == original && event.externalID == "event")
    }

    @Test
    func aCalendarMirrorChangedInAnotherContextRejectsTheSystemWrite() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let event = OneEvent(title: "Planning", start: original, durationMinutes: 30)
      event.externalID = "event"
      a.context.insert(event)
      try a.context.save()
      let other = ModelContext(a.context.container)
      let saved = try #require(try other.fetch(FetchDescriptor<OneEvent>()).first)
      saved.start = original.addingTimeInterval(900)
      try other.save()
      var writes = 0
      a.services.calendar.moveEventResult = { _, _ in
        writes += 1
        throw CalendarMoveError.stale
      }
      let result = ToolRegistry.apply(
        .init(
          expected: mirrorSnapshot(original, id: "event"), start: original.addingTimeInterval(1800)),
        context: a.context, calendar: a.services.calendar, ledger: a.services.ledger,
        report: { _ in })
      #expect(!result.result.applied && result.result.undo == nil && writes == 0)
      #expect(try a.rows().isEmpty)
    }

    private func mirrorSnapshot(_ start: Date, id: String) -> CalendarMoveSnapshot {
      CalendarMoveSnapshot(
        externalID: id, calendarID: "work", sourceID: "fixture", itemID: id,
        occurrence: start, start: start, end: start.addingTimeInterval(1800), isAllDay: false,
        lastModified: start, title: "Planning", location: nil, notes: nil, url: nil,
        audience: CalendarMoveAudience(attendeeCount: 0, isOrganizer: nil), participantIDs: [])
    }

    @Test
    func aSystemMoveExpectationCarriesItsLastModifiedTimeAndAudience() {
      let modified = Date(timeIntervalSince1970: 1_792_400_000)
      let start = modified.addingTimeInterval(86_400)
      let snapshot = CalendarMoveSnapshot(
        externalID: "ek", calendarID: "work", sourceID: "local", itemID: "item",
        occurrence: start, start: start, end: start.addingTimeInterval(1800), isAllDay: false,
        lastModified: modified, title: "Board call", location: nil, notes: nil, url: nil,
        audience: CalendarMoveAudience(attendeeCount: 3, isOrganizer: true),
        participantIDs: ["a", "b", "c"])
      let expected = SystemMoveProposal(expected: snapshot, start: start).snapshot
      #expect(
        expected
          == ProposalSnapshot(lastModified: modified, start: start, attendees: 3, repeats: false))
    }
  }

  @MainActor
  private final class RegistryFixture {
    let suite = "ToolRegistryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let runtime: PlannerRuntime
    let context: ModelContext
    let services: PlannerTestServices
    var now: Date { runtime.now() }

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let fixed = Date(timeIntervalSince1970: 1_792_486_800)
      runtime = PlannerRuntime(
        now: { fixed }, nextID: { UUID() }, calendar: calendar,
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
        container: container, defaults: defaults, runtime: runtime, arguments: [])
    }

    func dispose() {
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
    }

    func task(_ title: String, due: Date) -> OneTask {
      let task = OneTask(title: title, due: due)
      context.insert(task)
      try? context.save()
      return task
    }

    func apply(_ p: ChangeProposal) -> WriteResult {
      ToolRegistry.apply(
        p, context: context, calendar: services.calendar, actions: services.actions,
        ledger: services.ledger)
    }

    func rows() throws -> [LedgerItem] {
      services.ledger.flush(context)
      return try services.activityStore.page(ActivityQuery(tiers: [.changes]), limit: 150).map {
        LedgerItem(event: $0)
      }
    }
  }
#endif

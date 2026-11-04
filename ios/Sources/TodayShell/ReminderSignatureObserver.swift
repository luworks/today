#if os(iOS)
  import One
  import SwiftUI
  import SwiftData

  /// Watches every reminder, event and alarm and resyncs notifications, AlarmKit and widgets when one changes.
  /// It owns the store queries so a save re-renders only this empty view, not the whole shell and the sheet over
  /// it (a save under Add Alarm made the wheel stutter).
  struct ReminderSignatureObserver: View {
    let session: PlannerSession
    @Environment(\.modelContext) private var context
    @Query private var allTasks: [OneTask]
    @Query private var allEvents: [OneEvent]
    @Query private var allAlarms: [OneAlarm]

    var body: some View {
      Color.clear
        .accessibilityHidden(true)
        .task(id: signature) {
          try? await Task.sleep(for: .milliseconds(300))
          allAlarms.forEach { $0.retireIfRung(now: session.runtime.now()) }
          await session.notifications.resync()
          await session.alarms.sync(context)
          session.widget.update(
            tasks: allTasks, events: allEvents, alarms: allAlarms, now: session.runtime.now(),
            calendar: session.runtime.calendar)
        }
    }

    /// Changes whenever anything that affects reminders changes.
    private var signature: Int {
      var h = Hasher()
      for t in allTasks {
        h.combine(t.title)
        h.combine(t.isDone)
        h.combine(t.due)
        h.combine(t.reminderOffsetMinutes)
        h.combine(t.ringsAsAlarm)
      }
      for a in allAlarms { h.combine(a.scheduleSignature) }
      for e in allEvents {
        h.combine(e.title)
        h.combine(e.start)
        h.combine(e.reminderOffsetMinutes)
        h.combine(e.repeatRule)
        for occurrence in e.occurrenceOverrides {
          h.combine(occurrence.original)
          h.combine(occurrence.start)
        }
        h.combine(e.isAllDay)
        h.combine(e.ringsAsAlarm)
      }
      return h.finalize()
    }

    /// Rewrites the Lock Screen / Home Screen widget snapshot (skipped when nothing changed).
    @MainActor static func updateWidgets(session: PlannerSession, context: ModelContext) {
      session.widget.update(
        tasks: (try? context.fetch(FetchDescriptor<OneTask>())) ?? [],
        events: (try? context.fetch(FetchDescriptor<OneEvent>())) ?? [],
        alarms: (try? context.fetch(FetchDescriptor<OneAlarm>())) ?? [],
        now: session.runtime.now(), calendar: session.runtime.calendar)
    }
  }

  #if DEBUG
    /// `-uiTestingStoreChurn`: saves a reminder five times a second and shows how often the shell re-rendered,
    /// so a UI test can check that saves under an open sheet stay off the shell.
    struct StoreChurnProbe: View {
      @MainActor static var shellBodies = 0
      @MainActor static func countShellBody() { shellBodies += 1 }
      @Environment(\.modelContext) private var context
      @State private var report = ""

      var body: some View {
        Text(report).font(.system(size: 1)).opacity(0.01)
          .accessibilityIdentifier("storeChurn.report")
          .accessibilityLabel(report)
          .allowsHitTesting(false)
          .task {
            let task = OneTask(title: "Churn")
            context.insert(task)
            var saves = 0
            while !Task.isCancelled {
              try? await Task.sleep(for: .milliseconds(200))
              saves += 1
              task.note = String(saves)
              try? context.save()
              report = "saves=\(saves) shell=\(Self.shellBodies)"
            }
          }
      }
    }
  #endif
#endif

#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import SwiftData
  import UIKit

  /// The app side of the Activity data store: where the file lives, the one recorder every screen writes through, the outbox the
  /// extensions leave events in, pruning, export and Clear. The pure parts are in `Activity*.swift` (tested with `swift test`).
  ///
  /// Rules (document §3): only this process opens `activity.sqlite`; extensions append to the App Group outbox; the Activity screen
  /// pages through the store (150 rows at a time); text that is personal content stays in its own columns and tables.
  @MainActor
  package final class ActivityCenter {
    package let store: ActivityStore?
    package let recorder: ActivityRecorder
    package let didChange = Notification.Name("ActivityCenter.didChange")
    private let defaults: UserDefaults
    private let runtime: PlannerRuntime
    private let scheduledFlushes: FlushSchedule
    private var disposed = false

    /// Construction never selects or opens a database and never starts live lifecycle work.
    package init(store: ActivityStore?, defaults: UserDefaults, runtime: PlannerRuntime) {
      self.store = store
      self.defaults = defaults
      self.runtime = runtime
      let schedule = FlushSchedule()
      scheduledFlushes = schedule
      recorder = ActivityRecorder(
        store: store, session: runtime.nextID().uuidString,
        settings: { ActivitySettings(defaults) },
        schedule: { delay, work in schedule.enqueue(delay: delay, work: work) })
      recorder.didFlush = { [weak self] n in
        guard n > 0 else { return }
        Task { @MainActor [weak self] in
          guard let self, !self.disposed else { return }
          NotificationCenter.default.post(name: self.didChange, object: self)
        }
      }
    }

    @MainActor
    private final class FlushSchedule {
      private var tasks: [UUID: Task<Void, Never>] = [:]
      private var disposed = false
      func enqueue(delay: TimeInterval, work: @escaping @MainActor @Sendable () -> Void) {
        guard !disposed else { return }
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(delay)) } catch { return }
          guard let self, !self.disposed, !Task.isCancelled else { return }
          work()
          self.tasks[id] = nil
        }
      }
      func dispose() {
        disposed = true
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
      }
    }

    package func dispose() {
      recorder.flush()
      recorder.didFlush = nil
      scheduledFlushes.dispose()
      disposed = true
    }

    package var settings: ActivitySettings { ActivitySettings(defaults) }

    // MARK: Recording

    /// Records one event (dropped when its category is off or paused).
    package func record(_ event: ActivityEvent) {
      guard !disposed else { return }
      recorder.record(event)
    }

    /// Values only: immutable plan observations share the Changes retention and pause policy.
    package func observePlan(
      title: String, kind: String, reference: String, start: Date,
      end: Date?, allDay: Bool, calendar: Calendar
    ) {
      guard !disposed, recorder.isRecording(.changes), let store else { return }
      let now = runtime.now()
      let cleared = defaults.double(forKey: "activity.planClearBoundary")
      guard cleared == 0 || start.timeIntervalSince1970 >= cleared else { return }
      // Bounded indexed lookup; flush first so repeated refreshes do not enqueue duplicates.
      recorder.flush()
      let prior =
        (try? store.page(
          ActivityQuery(
            subjectRef: reference,
            kinds: [DayHistory.observationKind]), limit: 200)) ?? []
      if let last = prior.first(where: { $0.beforeTs == ActivityClock.ms(start) }),
        last.title == title, last.afterTs == end.map(ActivityClock.ms),
        (ActivityProps.dictionary(last.props)["all_day"] as? Bool) == allDay
      {
        return
      }
      var event = ActivityEvent(
        kind: DayHistory.observationKind, tier: .changes,
        actor: "system", at: now, calendar: calendar)
      event.title = title
      event.subjectKind = kind
      event.subjectRef = reference
      event.beforeTs = ActivityClock.ms(start)
      event.afterTs = end.map(ActivityClock.ms)
      event.props = ActivityProps.json([
        "observed_ms": ActivityClock.ms(now), "all_day": allDay,
        "plan_tz_minutes": calendar.timeZone.secondsFromGMT(for: start) / 60,
      ])
      recorder.record(event)
    }

    /// Whether changes (tier 1) are being kept. When not, nothing applies by itself under a grant: an automatic change without
    /// an Activity entry and an Undo would break "AI prepares, the user decides".
    package var recordsChanges: Bool { recorder.isRecording(.changes) }

    /// Writes what is buffered, inside a background task so the write finishes if the app is being suspended.
    package func flushInBackground() {
      let app = UIApplication.shared
      var task = UIBackgroundTaskIdentifier.invalid
      task = app.beginBackgroundTask(withName: "activity.flush") {
        app.endBackgroundTask(task)
        task = .invalid
      }
      recorder.flush()
      if task != .invalid { app.endBackgroundTask(task) }
    }

    // MARK: Launch and activation

    /// Brings in what the Share extension and widgets left behind. Called when the app becomes active.
    package func importOutbox() {
      let files = ActivityOutbox.pendingFiles()
      guard !files.isEmpty else { return }
      let read = ActivityOutboxImport.read(files)
      for e in read.events { recorder.record(e) }
      // Keep the source files until the database transaction has committed. Reimports are
      // idempotent by event UUID if an earlier attempt already wrote some events.
      if recorder.flush() { ActivityOutbox.remove(read.done) }
    }

    /// Drops expired rows (once per launch) according to the retention setting.
    package func prune() {
      guard let store = store else { return }
      _ = try? store.prune(retention: settings.retention, now: runtime.now())
    }

    // MARK: Numbers for Settings

    package struct Summary {
      package init(perTier: [ActivityTier: Int] = [:], fileBytes: Int64 = 0) {
        self.perTier = perTier
        self.fileBytes = fileBytes
      }
      package var perTier: [ActivityTier: Int] = [:]
      package var fileBytes: Int64 = 0
      package var total: Int { perTier.values.reduce(0, +) }
    }

    package func summary() -> Summary {
      recorder.flush()
      guard let store = store else { return Summary() }
      return Summary(perTier: (try? store.countByTier()) ?? [:], fileBytes: store.fileSize())
    }

    // MARK: Clear and export

    /// Deletes recorded activity (all of it, or some categories) and anything still waiting to be written. Never touches
    /// reminders, events, alarms, Apple Calendar or Apple Reminders.
    package func clear(tiers: Set<ActivityTier>? = nil) {
      if tiers == nil || tiers?.contains(.changes) == true {
        defaults.set(runtime.now().timeIntervalSince1970, forKey: "activity.planClearBoundary")
      }
      recorder.discardBuffered()
      try? store?.clear(tiers: tiers)
      NotificationCenter.default.post(name: didChange, object: self)
    }

    /// Writes the export to an explicitly selected artifact file and returns it (for the share sheet). Runs off the main thread.
    package func export(_ format: ActivityExportFormat, to url: URL) async throws -> URL {
      recorder.flush()
      guard let store = store else { throw ActivityStoreError.open("no store") }
      try await Task.detached(priority: .utility) {
        _ = try ActivityExport.write(format, from: store, to: url)
      }.value
      return url
    }
  }

#endif

#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import AppIntents
  #if canImport(AlarmKit)
    import AlarmKit
  #endif

  /// Every countdown timer Today started (AlarmKit): the ones set on the Timer tab (Apple-style picker and
  /// Recents, including the Focus / break presets) and the ones started by voice ("Start a timer in Today for 10 minutes"),
  /// Siri, Shortcuts or the Clock schema. Any number run at once, except that a Focus / break preset replaces the
  /// previous one. They ring full-screen through Silent and Focus, even with the app closed.
  ///
  /// AlarmKit has no fire date on `Alarm` and lists only this app's own alarms (never the Clock app's, never Siri's
  /// built-in timers), so the end times live in `TimerStore` (UserDefaults), keyed by the AlarmKit id.
  /// `Ringer.sync` keeps those ids when it cancels leftovers. The pure parts are in TimerList.swift.
  @MainActor
  @Observable
  package final class TimerController: TimerService {

    /// All running timers, in the order they were started.
    package private(set) var timers: [RunningTimer]
    /// Ids that are ringing right now.
    package private(set) var ringing: Set<UUID> = []
    /// Today's Pomodoro rounds (UserDefaults, starts over at midnight).
    package private(set) var log: PomodoroLog
    /// The Recents under the picker: what was started, newest first (UserDefaults; `TimerRecents`).
    package private(set) var recents: [RecentTimer]
    /// The tone new timers ring with: a name from `AlarmSound.all`, empty for the system alarm sound.
    package var sound: String { didSet { defaults.set(sound, forKey: Self.soundKey) } }
    /// A short line under the controls, e.g. when alarms are not allowed.
    package var message: String?

    private static let soundKey = "timer.sound"

    private let defaults: UserDefaults
    private let runtime: PlannerRuntime
    private let driver: Ringer
    private let donate: (Int) -> Void
    private var starting = false

    package init(
      defaults: UserDefaults, runtime: PlannerRuntime, driver: Ringer,
      donate: @escaping (Int) -> Void
    ) {
      self.defaults = defaults
      self.runtime = runtime
      self.driver = driver
      self.donate = donate
      driver.requireTimerDefaults(defaults)
      timers = TimerStore.load(defaults)
      recents = TimerRecentsStore.load(defaults)
      sound = defaults.string(forKey: Self.soundKey) ?? ""
      log = PomodoroLog.load(defaults, now: runtime.now(), calendar: runtime.calendar)
    }

    // MARK: Start, pause, resume, stop

    /// Starts a countdown and adds it to the Recents. Timers run next to each other, except that a Focus / break preset
    /// (25:00 "Focus", 5:00 "Short break", 15:00 "Long break": the only ones that count Pomodoro rounds) replaces the
    /// previous one. `byHand`: the user set it on the Timer tab, which teaches Siri the phrase.
    @discardableResult
    package func start(seconds: Int, label: String? = nil, byHand: Bool = false) async
      -> RunningTimer?
    {
      guard !starting, seconds > 0 else { return nil }
      starting = true
      defer { starting = false }
      message = nil
      let seconds = min(seconds, TimerDial.maxSeconds)
      let label = IntentTimer.label(label)
      let phase = Pomodoro.preset(seconds: seconds, label: label)
      if phase != nil { setLog { $0.pending = nil } }
      let id = runtime.nextID()
      let timer = RunningTimer.start(
        id: id, seconds: seconds, now: runtime.now(), phase: phase ?? .focus, label: label,
        source: phase == nil ? .voice : .card)
      let previous = phase == nil ? nil : timers.first { $0.isCard }
      #if canImport(AlarmKit)
        if driver.authorization == .notDetermined {
          await driver.requestAuthorization()
        }
        guard driver.authorization == .authorized else {
          message = "Timers need alarm access. Allow alarms for Today in Settings."
          return nil
        }
        if let previous { try? driver.manager.cancel(id: previous.id) }
        // Saved before scheduling so a sync that runs on the AlarmKit update keeps it.
        driver.claimTimer(id)
        defer { driver.releaseTimer(id) }
        set(TimerList.adding(timer, to: timers))
        do {
          _ = try await driver.manager.schedule(
            id: id, configuration: Self.configuration(for: timer, sound: sound))
          guard !Task.isCancelled, timers.contains(where: { $0.id == id }) else {
            try? driver.manager.cancel(id: id)
            set(timers.filter { $0.id != id })
            return nil
          }
          AlarmScheduler.log.info("timer scheduled \(seconds)s")
          remember(seconds, label)
          // Starting by hand teaches Siri the phrase: it can then suggest "Start a timer in Today" for this length.
          if byHand { donate(seconds) }
          return timer
        } catch {
          AlarmScheduler.log.error("timer failed \((error as NSError).code, privacy: .public)")
          set(timers.filter { $0.id != id })
          message = "Couldn't start the timer."
          return nil
        }
      #else
        message = "Timers need alarm access."
        return nil
      #endif
    }

    package func pause(_ id: UUID) {
      guard let timer = timers.first(where: { $0.id == id }), !timer.isPaused else { return }
      do {
        #if canImport(AlarmKit)
          do { try driver.manager.pause(id: id) } catch {
            message = "Couldn't pause the timer."
            return
          }
        #endif
      }
      replace(timer.paused(now: runtime.now()))
    }

    package func resume(_ id: UUID) {
      guard let timer = timers.first(where: { $0.id == id }), timer.isPaused else { return }
      do {
        #if canImport(AlarmKit)
          do { try driver.manager.resume(id: id) } catch {
            message = "Couldn't resume the timer."
            return
          }
        #endif
      }
      replace(timer.resumed(now: runtime.now()))
    }

    /// Cancel while counting down (no round), or Stop while ringing (the round already counted when it rang).
    package func cancel(_ id: UUID) {
      guard let timer = timers.first(where: { $0.id == id }) else { return }
      if ringing.contains(id), timer.isCard { complete(timer) }
      do {
        #if canImport(AlarmKit)
          if ringing.contains(id) { try? driver.manager.stop(id: id) }
          try? driver.manager.cancel(id: id)
        #endif
      }
      ringing.remove(id)
      set(timers.filter { $0.id != id })
    }

    // MARK: Recents

    private func remember(_ seconds: Int, _ label: String?) {
      setRecents(TimerRecents.recording(RecentTimer(seconds: seconds, label: label), in: recents))
    }

    /// Swipe to delete on a Recents row.
    package func deleteRecent(id: String) {
      setRecents(TimerRecents.removing(id: id, from: recents))
    }

    private func setRecents(_ list: [RecentTimer]) {
      recents = list
      TimerRecentsStore.save(list, defaults)
    }

    /// Lines the list up with AlarmKit (`TimerList.reconcile`): a timer it no longer has (rang and was stopped, or
    /// cancelled from the Lock Screen) leaves; pause/resume done outside the app is followed; the list is read again
    /// from storage first, so a timer started by an intent while the app was closed appears at once.
    /// A Focus round counts only when its countdown ran out: seen ringing, or gone at or after its end time
    /// (stopped from the Lock Screen while the app was closed). Gone early means cancelled: no round.
    package func refresh() {
      guard !starting else { return }
      setLog { _ in }  // midnight reset
      #if canImport(AlarmKit)
        let stored = TimerStore.load(defaults)
        var live: [UUID: LiveTimerState] = [:]
        for alarm in (try? driver.manager.alarms) ?? [] {
          switch alarm.state {
          case .alerting: live[alarm.id] = .ringing
          case .paused: live[alarm.id] = .paused
          default: live[alarm.id] = .running
          }
        }
        let result = TimerList.reconcile(local: stored, live: live, now: runtime.now())
        for timer in result.finished where timer.isCard { complete(timer) }
        if result.ringing != ringing { ringing = result.ringing }
        if result.timers != timers || result.timers != stored { set(result.timers) }
      #else
        set([])
      #endif
    }

    /// Follows AlarmKit until the calling task is cancelled (attach it to a view with `.task`), so a timer that ends,
    /// or is paused on the Lock Screen, shows up on whatever tab is open.
    package func watch() async {
      refresh()
      #if canImport(AlarmKit)
        for await _ in driver.manager.alarmUpdates {
          guard !Task.isCancelled else { return }
          refresh()
        }
      #endif
    }

    private func complete(_ timer: RunningTimer) {
      setLog {
        $0 = $0.completing(
          timer.pomodoroPhase, id: timer.id, now: runtime.now(), calendar: runtime.calendar)
      }
    }

    private func setLog(_ change: (inout PomodoroLog) -> Void) {
      var next = log.current(runtime.now(), calendar: runtime.calendar)
      change(&next)
      if next != log {
        log = next
        PomodoroLog.save(next, defaults)
      }
    }

    private func replace(_ timer: RunningTimer) {
      set(timers.map { $0.id == timer.id ? timer : $0 })
    }

    private func set(_ list: [RunningTimer]) {
      timers = list
      TimerStore.save(list, defaults)
    }

    // MARK: AlarmKit configuration

    #if canImport(AlarmKit)
      nonisolated private static func configuration(for timer: RunningTimer, sound: String)
        -> AlarmManager.AlarmConfiguration<AlarmScheduler.Meta>
      {
        // "Focus", "Break" or the user's name: the full-screen alert, the Lock Screen and the Dynamic Island show this.
        let title = LocalizedStringResource(stringLiteral: TimerList.title(timer))
        let alert = AlarmPresentation.Alert(title: title)
        let presentation = AlarmPresentation(
          alert: alert,
          countdown: AlarmPresentation.Countdown(
            title: title,
            pauseButton: AlarmButton(
              text: "Pause", textColor: .orange, systemImageName: "pause.fill")),
          paused: AlarmPresentation.Paused(
            title: "Paused",
            resumeButton: AlarmButton(
              text: "Resume", textColor: .orange, systemImageName: "play.fill")))
        let attributes = AlarmAttributes<AlarmScheduler.Meta>(
          presentation: presentation, metadata: AlarmMeta(kind: .timer), tintColor: .orange)
        // The entity lets Siri act on this very timer ("pause the timer", "add 5 minutes"): iOS 27.
        return .timer(
          duration: TimeInterval(timer.total), attributes: attributes,
          appEntityIdentifier: EntityIdentifier(for: TimerEntity.self, identifier: timer.id),
          sound: AlarmSound.named(sound)?.alertSound ?? .default)
      }
    #endif
  }
#endif

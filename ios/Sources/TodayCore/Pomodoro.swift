import Foundation

/// A restrained Pomodoro on top of the Apple-style Timers screen: three preset rows (25:00 Focus, 5:00 Short break,
/// 15:00 Long break). A timer whose length and label match a preset is a Pomodoro timer. Only a Focus countdown that
/// runs to the end counts as a round (cancelled ones do not). Rounds are per day and start over at midnight.
/// Foundation only, so it runs under `swift test`.
public enum PomodoroPhase: String, Codable, Equatable, Sendable {
  case focus, shortBreak, longBreak

  public var minutes: Int {
    switch self {
    case .focus: 25
    case .shortBreak: 5
    case .longBreak: 15
    }
  }

  public var seconds: Int { minutes * 60 }
  public var isBreak: Bool { self != .focus }

  /// The Live Activity and alert title: "Focus" or "Break" (never "Timer").
  public var title: String { isBreak ? "Break" : "Focus" }

  /// The name on the preset row ("Focus", "Short break", "Long break"): the label a timer carries.
  public var presetLabel: String {
    switch self {
    case .focus: "Focus"
    case .shortBreak: "Short break"
    case .longBreak: "Long break"
    }
  }
}

public enum Pomodoro {
  /// The preset rows, in order.
  public static let chips: [PomodoroPhase] = [.focus, .shortBreak, .longBreak]
  /// Every 4th Focus round of the day earns a long break.
  public static let roundsPerSet = 4

  /// The Pomodoro phase a timer of `seconds` called `label` is, or nil for any other timer: only an exact preset
  /// (25:00 "Focus", 5:00 "Short break", 15:00 "Long break") counts, so a custom 7-minute timer never makes a round.
  public static func preset(seconds: Int, label: String?) -> PomodoroPhase? {
    guard let name = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return nil
    }
    return chips.first { $0.seconds == seconds && $0.presetLabel.lowercased() == name }
  }

  /// The one next step after a countdown ends. After Focus: a short break, or a long break when today's
  /// round count is a multiple of 4. After a break: Focus again.
  public static func next(after finished: PomodoroPhase, roundsToday: Int) -> PomodoroPhase {
    guard finished == .focus else { return .focus }
    return roundsToday > 0 && roundsToday % roundsPerSet == 0 ? .longBreak : .shortBreak
  }

  /// "No focus rounds yet today", "1 focus round today", "3 focus rounds today" (VoiceOver).
  public static func spokenRounds(_ rounds: Int) -> String {
    if rounds <= 0 { return "No focus rounds yet today" }
    return "\(rounds) focus \(rounds == 1 ? "round" : "rounds") today"
  }

  /// "2026-10-16" in the given calendar: the day stamp rounds are stored under.
  public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}

/// Today's Pomodoro record, kept in UserDefaults under a day stamp so it starts over at midnight.
public struct PomodoroLog: Codable, Equatable {
  /// The day the rounds belong to (`Pomodoro.dayKey`).
  public var day: String
  /// Focus countdowns that ran to the end that day.
  public var rounds: Int = 0
  /// What just ended, while the card offers the next step; nil after "Done for now" or a new start.
  public var pending: PomodoroPhase?
  /// The countdown counted last, so a ring seen twice (alerting, then gone) counts once.
  public var lastCountedID: UUID?

  public static func empty(_ now: Date, calendar: Calendar = .current) -> PomodoroLog {
    PomodoroLog(day: Pomodoro.dayKey(now, calendar: calendar))
  }

  /// This log as seen at `now`: a log from an earlier day becomes an empty one (midnight reset).
  public func current(_ now: Date, calendar: Calendar = .current) -> PomodoroLog {
    day == Pomodoro.dayKey(now, calendar: calendar) ? self : .empty(now, calendar: calendar)
  }

  /// A countdown of `phase` ran to the end at `now`. Focus adds a round; either way the card offers the next step.
  public func completing(_ phase: PomodoroPhase, id: UUID, now: Date, calendar: Calendar = .current)
    -> PomodoroLog
  {
    var log = current(now, calendar: calendar)
    guard log.lastCountedID != id else { return log }
    log.lastCountedID = id
    if phase == .focus { log.rounds += 1 }
    log.pending = phase
    return log
  }

  /// The step the card offers now, if any.
  public var nextStep: PomodoroPhase? {
    pending.map { Pomodoro.next(after: $0, roundsToday: rounds) }
  }

  // MARK: Storage

  public static let defaultsKey = "pomodoro.log"

  public static func load(
    _ defaults: UserDefaults = .standard, now: Date = .now, calendar: Calendar = .current
  ) -> PomodoroLog {
    guard let data = defaults.data(forKey: defaultsKey),
      let log = try? JSONDecoder().decode(PomodoroLog.self, from: data)
    else { return .empty(now, calendar: calendar) }
    return log.current(now, calendar: calendar)
  }

  public static func save(_ log: PomodoroLog, _ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: defaultsKey) }
  }

  public init(
    day: String, rounds: Int = 0, pending: PomodoroPhase? = nil, lastCountedID: UUID? = nil
  ) {
    self.day = day
    self.rounds = rounds
    self.pending = pending
    self.lastCountedID = lastCountedID
  }
}

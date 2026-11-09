import Foundation

/// One-tap starting points for a new alarm, all from the user's own alarms: the times and names they use most, a nap
/// "in 20 min", and the Clock repeat presets. Shared by Add Alarm's chips and the chat's wake-up suggestion, so both
/// offer the same times. A pick only fills the editor or the sentence; saving still takes the user's tap.
public enum AlarmQuickPicks {
  public struct Time: Hashable, Sendable {
    public let hour: Int
    public let minute: Int
    public init(hour: Int, minute: Int) {
      self.hour = hour
      self.minute = minute
    }
  }

  /// Shown until the user has alarms of their own.
  public static let fallbackTimes = [
    Time(hour: 6, minute: 30), Time(hour: 7, minute: 0), Time(hour: 7, minute: 30),
  ]
  /// "In 20 min" / "In 30 min": a nap or a short break.
  public static let napMinutes = [20, 30]

  /// Up to `limit` times, most used first (a tie goes to the earlier time); filled from `fallbackTimes` when the
  /// history has fewer distinct times.
  public static func times(history: [Time], limit: Int = 3) -> [Time] {
    var picks = mostUsed(history).prefix(limit).map { $0 }
    for time in fallbackTimes where picks.count < limit && !picks.contains(time) {
      picks.append(time)
    }
    return picks
  }

  /// Up to `limit` names the user has given alarms, most used first (ties keep the order given). Blank names and Clock's
  /// "Alarm" are skipped; names that differ only in case or surrounding spaces count as one.
  public static func labels(history: [String], limit: Int = 3) -> [String] {
    var counts: [String: Int] = [:]
    var first: [String: (index: Int, text: String)] = [:]
    for (index, raw) in history.enumerated() {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = text.lowercased()
      guard !text.isEmpty, key != AlarmPlan.defaultLabel.lowercased() else { continue }
      counts[key, default: 0] += 1
      if first[key] == nil { first[key] = (index, text) }
    }
    return counts.keys
      .sorted { a, b in
        counts[a]! != counts[b]! ? counts[a]! > counts[b]! : first[a]!.index < first[b]!.index
      }
      .prefix(limit)
      .map { first[$0]!.text }
  }

  /// The clock time `minutes` from now ("In 20 min" at 23:50 → 00:10).
  public static func time(inMinutes minutes: Int, from now: Date, calendar: Calendar = .current)
    -> Time
  {
    let date = now.addingTimeInterval(TimeInterval(minutes * 60))
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return Time(hour: c.hour ?? 0, minute: c.minute ?? 0)
  }

  /// Clock's repeat presets, as one-tap pills above the weekday circles.
  public enum RepeatPreset: String, CaseIterable, Sendable {
    case weekdays, weekends, everyDay

    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    public var weekdays: Set<Int> {
      switch self {
      case .weekdays: [2, 3, 4, 5, 6]
      case .weekends: [1, 7]
      case .everyDay: Set(1...7)
      }
    }

    /// The same words Repeat shows for these days.
    public var title: String { AlarmPlan.repeatValue(weekdays: Array(weekdays)) }

    /// The preset these days are exactly, if any.
    public static func matching(_ days: Set<Int>) -> RepeatPreset? {
      allCases.first { $0.weekdays == days }
    }
  }

  private static func mostUsed(_ history: [Time]) -> [Time] {
    var counts: [Time: Int] = [:]
    for time in history { counts[time, default: 0] += 1 }
    return counts.keys.sorted { a, b in
      counts[a]! != counts[b]!
        ? counts[a]! > counts[b]! : (a.hour, a.minute) < (b.hour, b.minute)
    }
  }
}

extension AlarmPlan {
  /// What a new alarm starts with, wherever it is made (Add Alarm, the chat, Siri): Snooze on, and the sound and
  /// snooze length chosen in Settings → Alarms.
  public struct NewAlarmDefaults: Equatable, Sendable {
    public let snooze: Bool
    public let snoozeMinutes: Int
    public let sound: String
  }

  public static func newAlarmDefaults(_ defaults: UserDefaults = .standard) -> NewAlarmDefaults {
    NewAlarmDefaults(
      snooze: true, snoozeMinutes: Preferences.newAlarmSnoozeMinutes(defaults),
      sound: Preferences.newAlarmSoundName(defaults))
  }

  /// A sound changed in the alarm editor becomes what the next new alarm starts with (owner request, 2026-11-09),
  /// the same preference Settings → Alarms shows. Default ("") counts as a choice. A save that left the sound as it
  /// opened changes nothing, so editing an old alarm's time cannot turn its sound into the default.
  public static func rememberSound(
    saved: String, opened: String, _ defaults: UserDefaults = .standard
  ) {
    guard saved != opened else { return }
    defaults.set(saved, forKey: Preferences.newAlarmSoundKey)
  }
}

import Foundation

/// Settle belongs to the device's current day only. A past day shows what happened on it (`DayHistory`) and a future
/// day shows its plan; neither offers Settle, lists Settled items or hides a row because of a Settle choice.
public enum SettleGate {
  /// Whether Settle (the action, the Settled section and hiding settled rows) applies to `day` at `now`.
  public static func applies(to day: Date, now: Date, calendar: Calendar) -> Bool {
    calendar.isDate(day, inSameDayAs: now)
  }
}

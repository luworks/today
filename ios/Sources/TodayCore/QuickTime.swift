import Foundation

/// The rules behind the quick-add grid (modeled on Due): one tap sets or nudges the reminder's time, no date picker needed.
public enum QuickTime {
  /// The four times of day on the grid's first row.
  public static let presets: [(hour: Int, minute: Int)] = [(9, 30), (12, 0), (18, 30), (22, 0)]

  /// The four preset times as minutes of the day, in stored order. Anything but exactly four valid
  /// times is the shipped four.
  public static func presetMinutes(stored: String?) -> [Int] {
    let parts = (stored ?? "").split(separator: ",").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0..<1440).contains($0) }) else {
      return presets.map { $0.hour * 60 + $0.minute }
    }
    return parts
  }

  /// The grid's first row: the chosen times, earliest first.
  public static func presets(stored: String?) -> [(hour: Int, minute: Int)] {
    presetMinutes(stored: stored).sorted().map { (hour: $0 / 60, minute: $0 % 60) }
  }

  /// What Settings stores for these times.
  public static func storedPresets(_ minutes: [Int]) -> String {
    minutes.map(String.init).joined(separator: ",")
  }

  /// The nudges on the second (+) and third (−) rows, in minutes.
  public static let nudges: [Int] = [10, 60, 180, 1440]

  public enum Day: String, CaseIterable, Identifiable {
    case today = "Today", tomorrow = "Tomorrow", weekend = "This Weekend", nextWeek = "Next Week"
    public var id: Self { self }
  }

  /// A new reminder starts at the next quarter hour.
  public static func start(now: Date = .now, calendar cal: Calendar = .current) -> Date {
    let m = cal.component(.minute, from: now)
    let add = 15 - m % 15
    let next = cal.date(byAdding: .minute, value: add, to: now) ?? now
    return cal.date(bySetting: .second, value: 0, of: next) ?? next
  }

  /// A preset time on the chosen day; a time already past today moves to tomorrow.
  public static func preset(
    hour: Int, minute: Int, on date: Date, now: Date = .now, calendar cal: Calendar = .current
  ) -> Date {
    let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    guard d <= now, let next = cal.date(byAdding: .day, value: 1, to: d) else { return d }
    return next
  }

  /// Due-style preset: retain the selected calendar day even when the time is in the past.
  public static func presetOnSelectedDay(
    hour: Int, minute: Int, on date: Date, calendar: Calendar = .current
  ) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
  }

  public static func repeatLabel(
    _ rule: RepeatRule, date: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.dateFormat = "HH:mm"
    let time = formatter.string(from: date)
    switch rule {
    case .daily: return "Daily \(time)"
    case .weekdays: return "Weekdays \(time)"
    case .weekly:
      formatter.dateFormat = "EEEE"
      return "\(formatter.string(from: date))s \(time)"
    case .monthly:
      let number = NSNumber(value: calendar.component(.day, from: date))
      let ordinal = NumberFormatter()
      ordinal.locale = locale
      ordinal.numberStyle = .ordinal
      return "\(ordinal.string(from: number) ?? number.stringValue) each month at \(time)"
    case .yearly:
      formatter.dateFormat = "MMM d"
      return "Every \(formatter.string(from: date)) at \(time)"
    case .weeklyOn: return rule.label
    }
  }

  public static func nudge(_ date: Date, minutes: Int, calendar cal: Calendar = .current) -> Date {
    // A day button keeps wall-clock time across daylight-saving transitions.
    if abs(minutes) == 1440 {
      return cal.date(byAdding: .day, value: minutes / 1440, to: date) ?? date
    }
    return cal.date(byAdding: .minute, value: minutes, to: date) ?? date
  }

  /// Moves to a day, keeping the time of day. This Weekend = the coming Saturday; Next Week = next Monday.
  public static func move(
    _ date: Date, to day: Day, now: Date = .now, calendar cal: Calendar = .current
  ) -> Date {
    let today = cal.startOfDay(for: now)
    let target: Date
    switch day {
    case .today: target = today
    case .tomorrow: target = cal.date(byAdding: .day, value: 1, to: today) ?? today
    case .weekend:
      target =
        cal.nextDate(after: today, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)
        .map { cal.isDate($0, inSameDayAs: today) ? today : $0 } ?? today
    case .nextWeek:
      target =
        cal.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)
        ?? today
    }
    let t = cal.dateComponents([.hour, .minute], from: date)
    return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: target)
      ?? target
  }

  /// "Now", "in 25 min", "in 2 hr 30 min", "in 3 days", "10 min ago".
  public static func relative(_ date: Date, now: Date = .now) -> String {
    let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
    if abs(minutes) < 1 { return "Now" }
    let a = abs(minutes)
    let text: String
    if a < 60 {
      text = "\(a) min"
    } else if a < 1440 {
      text = a % 60 == 0 ? "\(a / 60) hr" : "\(a / 60) hr \(a % 60) min"
    } else {
      let d = Int((Double(a) / 1440).rounded())
      text = d == 1 ? "1 day" : "\(d) days"
    }
    return minutes > 0 ? "in " + text : text + " ago"
  }

  /// "+10 min", "+1 hr", "+3 hr", "+1 day" (and the − versions).
  public static func nudgeLabel(_ minutes: Int) -> String {
    let sign = minutes < 0 ? "−" : "+"
    let a = abs(minutes)
    if a >= 1440 { return sign + "\(a / 1440) day" }
    if a >= 60 { return sign + "\(a / 60) hr" }
    return sign + "\(a) min"
  }
}

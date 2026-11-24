import Foundation

/// A part of the day named by the user. Resolving it requires the local calendar.
public enum CaptureTimeWindow: String, Codable, Sendable {
  case morning, afternoon, evening

  var label: String { rawValue.capitalized }

  public var hours: Range<Int> {
    switch self {
    case .morning: 8..<12
    case .afternoon: 12..<18
    case .evening: 18..<21
    }
  }

  public static func detect(in text: String) -> Self? {
    let day =
      #"(?:this|today|tomorrow|in the|on the|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#
    let chineseDay = #"今天|明天|后天|(?:周|星期|礼拜)[一二三四五六日天]|提醒我|^"#
    let matches: [(Self, String, String)] = [
      (.morning, "早上|上午", "今早|明早"),
      (.afternoon, "下午", "今午|明午"),
      (.evening, "晚上", #"今晚|明晚|\btonight\b"#),
    ]
    let found = matches.filter { window, chinese, relative in
      let part = window.rawValue
      let pattern =
        relative + "|(?:" + chineseDay + ")(?:" + chinese + ")|(?:"
        + chinese + #")[。.!?？]?\s*$|\b"# + day + " " + part + #"\b|^"# + part + "$"
      return text.range(
        of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    return found.count == 1 ? found.first?.0 : nil
  }

  /// Prefer a familiar clock time if it still fits. Otherwise find the first whole-minute slot.
  public func suggestedTime(
    day: Date, now: Date, busy: [DateInterval], durationMinutes: Int, preferred: Date? = nil,
    calendar: Calendar
  ) -> Date? {
    guard let start = calendar.date(bySettingHour: hours.lowerBound, minute: 0, second: 0, of: day),
      let end = calendar.date(bySettingHour: hours.upperBound, minute: 0, second: 0, of: day)
    else { return nil }
    let duration = max(1, durationMinutes)
    guard duration <= hours.count * 60 else { return nil }
    let gaps = DaySchedule.freeGaps(
      busy: busy, day: day, now: now, minimum: duration, calendar: calendar)
    let seconds = TimeInterval(duration) * 60
    if let preferred {
      let clock = calendar.dateComponents([.hour, .minute], from: preferred)
      if let time = calendar.date(
        bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day),
        time >= start, time.addingTimeInterval(seconds) <= end,
        gaps.contains(where: { $0.start <= time && $0.end >= time.addingTimeInterval(seconds) })
      {
        return time
      }
    }
    for gap in gaps {
      let lower = max(start, gap.start)
      let minute = ceil(lower.timeIntervalSinceReferenceDate / 60) * 60
      let candidate = Date(timeIntervalSinceReferenceDate: minute)
      if candidate.addingTimeInterval(seconds) <= min(end, gap.end) { return candidate }
    }
    return nil
  }
}

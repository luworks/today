import Foundation

/// Localized top-bar dates: the browsed Calendar period, or the current month on other tabs.
public enum MonthLabel {
  public enum Length: Sendable { case full, short }

  public enum Period: Equatable, Sendable {
    case month(Date)
    case year(Date)
  }

  /// Month uses its committed page; 2 Day uses the first column even across a month/year boundary.
  /// Passing no visible range keeps the current-device-month contract of the other tabs.
  public static func period(
    now: Date, visibleDays: ClosedRange<Date>?, showsYear: Bool = false
  ) -> Period {
    guard let visibleDays else { return .month(now) }
    return showsYear ? .year(visibleDays.lowerBound) : .month(visibleDays.lowerBound)
  }

  public static func text(
    period: Period, length: Length = .short, calendar: Calendar, locale: Locale
  ) -> String {
    switch period {
    case .month(let date):
      return text(now: date, length: length, calendar: calendar, locale: locale)
    case .year(let date):
      let format = DateFormatter()
      format.calendar = calendar
      format.locale = locale
      format.timeZone = calendar.timeZone
      format.setLocalizedDateFormatFromTemplate("y")
      return format.string(from: date)
    }
  }

  public static func text(
    now: Date, length: Length = .short, calendar: Calendar, locale: Locale
  ) -> String {
    let format = DateFormatter()
    format.calendar = calendar
    format.locale = locale
    format.timeZone = calendar.timeZone
    format.setLocalizedDateFormatFromTemplate(length == .full ? "MMMMy" : "MMMy")
    return format.string(from: now)
  }
}

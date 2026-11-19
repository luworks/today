import Foundation

/// A second display zone never changes the planner's local dates or saved event instants.
public enum CalendarTimeZone {
  public static let enabledKey = "today.setting.calendarSecondZoneEnabled"
  public static let cityKey = "today.setting.calendarSecondZoneCity"
  public static let worldCitiesKey = "today.worldClock.cities"

  public static func city(stored: String) -> CityRecord? {
    guard let data = stored.data(using: .utf8),
      let city = try? JSONDecoder().decode(CityRecord.self, from: data), city.timeZone != nil
    else { return nil }
    return city
  }

  public static func selected(_ defaults: UserDefaults) -> CityRecord? {
    city(stored: defaults.string(forKey: cityKey) ?? "")
  }

  /// Selecting in Calendar adds the same stable city identity to World Clock, at most once.
  public static func choose(_ city: CityRecord, defaults: UserDefaults) {
    guard city.timeZone != nil, let data = try? JSONEncoder().encode(city),
      let encoded = String(data: data, encoding: .utf8)
    else { return }
    var keys = defaults.stringArray(forKey: worldCitiesKey) ?? []
    if !keys.contains(city.key) { keys.append(city.key) }
    defaults.set(keys, forKey: worldCitiesKey)
    defaults.set(encoded, forKey: cityKey)
    defaults.set(true, forKey: enabledKey)
  }

  /// Labels are derived for each day's absolute instant, including fractional offsets and repeated hours.
  public static func label(at instant: Date, zone: TimeZone, local: Calendar) -> String {
    var remote = local
    remote.timeZone = zone
    let c = remote.dateComponents([.hour, .minute, .era, .year, .month, .day], from: instant)
    let localDate = local.dateComponents([.era, .year, .month, .day], from: instant)
    var neutral = Calendar(identifier: .gregorian)
    neutral.timeZone = TimeZone(secondsFromGMT: 0)!
    let remoteDate = DateComponents(era: c.era, year: c.year, month: c.month, day: c.day)
    let delta =
      neutral.date(from: localDate).flatMap { start in
        neutral.date(from: remoteDate).map {
          neutral.dateComponents([.day], from: start, to: $0).day ?? 0
        }
      } ?? 0
    let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    return time + (delta == 0 ? "" : (delta > 0 ? " +\(delta)" : " −\(-delta)"))
  }

  /// The secondary label is visible only during the selected city's local working hours.
  public static func workingTimeLabel(at instant: Date, zone: TimeZone, local: Calendar) -> String?
  {
    var remote = local
    remote.timeZone = zone
    guard (8..<20).contains(remote.component(.hour, from: instant)) else { return nil }
    return label(at: instant, zone: zone, local: local)
  }

  public static func workingHourLabel(
    _ hour: Int, day: Date, zone: TimeZone, local: Calendar
  ) -> String? {
    let labels = CalendarDayAxis.instants(atHour: hour, on: day, calendar: local).compactMap {
      workingTimeLabel(at: $0, zone: zone, local: local)
    }
    return labels.isEmpty ? nil : labels.joined(separator: "/")
  }

  public static func hourLabel(_ hour: Int, day: Date, zone: TimeZone, local: Calendar) -> String {
    let labels = CalendarDayAxis.instants(atHour: hour, on: day, calendar: local).map {
      label(at: $0, zone: zone, local: local)
    }
    return labels.isEmpty ? "—" : labels.joined(separator: "/")
  }
}

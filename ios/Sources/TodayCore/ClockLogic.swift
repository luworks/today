import Foundation

/// The four parts of the Clock tab, like the tabs of Apple's Clock app. Shown as a small switcher under the top bar.
public enum ClockSection: String, CaseIterable, Identifiable {
  case alarms, worldClock, stopwatch, timer

  public var id: Self { self }

  public var title: String {
    switch self {
    case .alarms: "Alarms"
    case .worldClock: "World Clock"
    case .stopwatch: "Stopwatch"
    case .timer: "Timer"
    }
  }
}

// MARK: - World Clock

/// Pure logic behind World Clock: readable city names from time zone identifiers, "Today, +3 hrs", and the saved list.
public enum WorldClock {
  /// "America/New_York" → "New York", "America/Argentina/Buenos_Aires" → "Buenos Aires".
  /// nil for zones that are not a place ("UTC", "GMT", "Etc/GMT+5", "US/Pacific", "SystemV/…").
  public static func cityName(fromIdentifier identifier: String) -> String? {
    let parts = identifier.split(separator: "/")
    guard parts.count >= 2, let region = parts.first else { return nil }
    let regions: Set<Substring> = [
      "Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia", "Europe",
      "Indian", "Pacific",
    ]
    guard regions.contains(region), let last = parts.last else { return nil }
    return last.replacingOccurrences(of: "_", with: " ")
  }

  /// The difference to the local time, as Clock writes it: "+0 hrs", "+1 hr", "-5 hrs", "+5:30 hrs", "-3:30 hrs".
  /// Taken at `now`, so it follows daylight saving time in either zone.
  public static func offsetText(zone: TimeZone, local: TimeZone, at now: Date) -> String {
    let seconds = zone.secondsFromGMT(for: now) - local.secondsFromGMT(for: now)
    let sign = seconds < 0 ? "-" : "+"
    let minutes = abs(seconds) / 60
    let h = minutes / 60
    let m = minutes % 60
    if m != 0 { return "\(sign)\(h):" + String(format: "%02d", m) + " hrs" }
    return "\(sign)\(h) " + (h == 1 ? "hr" : "hrs")
  }

  /// Whether it is already tomorrow (or still yesterday) in the city: "Today", "Tomorrow" or "Yesterday".
  public static func dayLabel(zone: TimeZone, local: TimeZone, at now: Date) -> String {
    switch dayDifference(zone: zone, local: local, at: now) {
    case 1: "Tomorrow"
    case -1: "Yesterday"
    default: "Today"
    }
  }

  /// The city's calendar day minus the local calendar day (-1, 0 or 1).
  public static func dayDifference(zone: TimeZone, local: TimeZone, at now: Date) -> Int {
    func dayNumber(in tz: TimeZone) -> Int {
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = tz
      let c = cal.dateComponents([.year, .month, .day], from: now)
      var utc = Calendar(identifier: .gregorian)
      utc.timeZone = TimeZone(identifier: "UTC")!
      let midnight = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? now
      return Int((midnight.timeIntervalSince1970 / 86_400).rounded())
    }
    return dayNumber(in: zone) - dayNumber(in: local)
  }

  /// "Today, +3 hrs".
  public static func subtitle(zone: TimeZone, local: TimeZone, at now: Date) -> String {
    dayLabel(zone: zone, local: local, at: now) + ", "
      + offsetText(zone: zone, local: local, at: now)
  }

  /// Hour and minute on the city's clock, for `AlarmPlan.timeParts` (same big time as the alarm rows).
  public static func hourMinute(zone: TimeZone, at now: Date) -> (hour: Int, minute: Int) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let c = cal.dateComponents([.hour, .minute], from: now)
    return (c.hour ?? 0, c.minute ?? 0)
  }

  // MARK: Saved list

  /// Adds a city at the end; a city already in the list is not added twice.
  public static func adding(_ identifier: String, to list: [String]) -> [String] {
    list.contains(identifier) ? list : list + [identifier]
  }

  /// Reorders like `List.onMove`.
  public static func moving(_ list: [String], from source: IndexSet, to destination: Int)
    -> [String]
  {
    var out = list
    let moved = source.sorted().map { list[$0] }
    for i in source.sorted(by: >) { out.remove(at: i) }
    let shift = source.filter { $0 < destination }.count
    out.insert(contentsOf: moved, at: destination - shift)
    return out
  }

}

// MARK: - Stopwatch

/// The stopwatch as plain data: it never ticks, it only remembers when it started. The elapsed time is worked out
/// from `startedAt` whenever it is shown, so it keeps running while the app is in the background or closed.
public struct StopwatchState: Codable, Equatable {
  /// When the current run started; nil while stopped.
  public var startedAt: Date?
  /// Time banked by earlier runs (before the last Stop).
  public var accumulated: TimeInterval = 0
  /// Finished laps, oldest first, each as its own duration.
  public var laps: [TimeInterval] = []

  public var isRunning: Bool { startedAt != nil }

  /// True once it has been started and not reset: Lap turns into Reset when it is stopped.
  public var hasTime: Bool { isRunning || accumulated > 0 }

  public func elapsed(at now: Date) -> TimeInterval {
    accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
  }

  /// The lap in progress: elapsed time since the last finished lap.
  public func currentLap(at now: Date) -> TimeInterval {
    max(0, elapsed(at: now) - laps.reduce(0, +))
  }

  public mutating func start(at now: Date) {
    guard startedAt == nil else { return }
    startedAt = now
  }

  public mutating func stop(at now: Date) {
    guard startedAt != nil else { return }
    accumulated = elapsed(at: now)
    startedAt = nil
  }

  public mutating func lap(at now: Date) {
    guard isRunning else { return }
    laps.append(currentLap(at: now))
  }

  public mutating func reset() {
    self = StopwatchState()
  }

  // MARK: Lap stats

  /// Index (into `laps`) of the fastest finished lap, marked green. nil until there are two laps to compare.
  public var bestLapIndex: Int? {
    guard laps.count >= 2, Set(laps).count > 1 else { return nil }
    return laps.indices.min { laps[$0] < laps[$1] }
  }

  /// Index of the slowest finished lap, marked red. nil until there are two laps to compare.
  public var worstLapIndex: Int? {
    guard laps.count >= 2, Set(laps).count > 1 else { return nil }
    return laps.indices.max { laps[$0] < laps[$1] }
  }

  // MARK: Format

  /// "00:00.00" (minutes, seconds, hundredths), "1:02:03.45" past an hour. Truncates like Clock: never shows a time not yet reached.
  public static func format(_ t: TimeInterval) -> String {
    // 5.75 - 4.2 - 6.5 must not read 5.74
    let hundredths = Int((max(0, t) * 100 + 1e-6).rounded(.down))
    let cs = hundredths % 100
    let totalSeconds = hundredths / 100
    let s = totalSeconds % 60
    let m = (totalSeconds / 60) % 60
    let h = totalSeconds / 3600
    let tail = String(format: "%02d:%02d.%02d", m, s, cs)
    return h > 0 ? "\(h):" + tail : tail
  }

  // MARK: Persistence

  public static let defaultsKey = "today.stopwatch"

  public static func load(from defaults: UserDefaults, key: String = defaultsKey) -> StopwatchState
  {
    guard let data = defaults.data(forKey: key),
      let state = try? JSONDecoder().decode(StopwatchState.self, from: data)
    else { return StopwatchState() }
    return state
  }

  public func save(to defaults: UserDefaults, key: String = StopwatchState.defaultsKey) {
    if self == StopwatchState() {
      defaults.removeObject(forKey: key)
      return
    }
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
  }

  public init(startedAt: Date? = nil, accumulated: TimeInterval = 0, laps: [TimeInterval] = []) {
    self.startedAt = startedAt
    self.accumulated = accumulated
    self.laps = laps
  }
}

// MARK: - World Clock: scrubbing, time of day, overlap (modeled on the app "Overlap")

extension WorldClock {
  /// Scrubbing moves every city's clock together, in 15-minute steps, up to a day either way.
  public enum Scrub {
    public static let stepMinutes = 15
    public static let limitMinutes = 24 * 60
    /// Points of horizontal drag per 15-minute step.
    public static let pointsPerStep: Double = 10

    /// The offset (in minutes) for a drag: dragging left moves time forward; dragging right moves it backward.
    /// `start` is the offset when the drag began.
    public static func offset(start: Int, dragWidth: Double) -> Int {
      let steps = Int((dragWidth / pointsPerStep).rounded(.towardZero))
      return clamp(snap(start) - steps * stepMinutes)
    }

    /// Rounds to the nearest 15 minutes.
    static func snap(_ minutes: Int) -> Int {
      Int((Double(minutes) / Double(stepMinutes)).rounded()) * stepMinutes
    }

    static func clamp(_ minutes: Int) -> Int { min(limitMinutes, max(-limitMinutes, minutes)) }

    /// The moment the cards show: now plus the offset. Minutes are kept (18:50 minus 15 hours reads 03:50), as in Overlap.
    public static func date(now: Date, offset minutes: Int) -> Date {
      now.addingTimeInterval(Double(minutes) * 60)
    }

    /// The pill under the cities, in two parts so the keyword can be bold: ("", "NOW"), ("15 HOURS BEFORE ", "NOW"),
    /// ("1 HOUR 15 MIN AFTER ", "NOW"), ("45 MIN BEFORE ", "NOW").
    public static func pillParts(_ minutes: Int) -> (lead: String, keyword: String) {
      guard minutes != 0 else { return ("", "NOW") }
      let m = abs(minutes)
      let h = m / 60
      let rest = m % 60
      var parts: [String] = []
      if h > 0 { parts.append("\(h) " + (h == 1 ? "HOUR" : "HOURS")) }
      if rest > 0 { parts.append("\(rest) MIN") }
      return (parts.joined(separator: " ") + (minutes > 0 ? " AFTER " : " BEFORE "), "NOW")
    }

    /// The pill as one line: "NOW", "15 HOURS BEFORE NOW".
    public static func pillText(_ minutes: Int) -> String {
      let p = pillParts(minutes)
      return p.lead + p.keyword
    }

    /// How far the page follows the finger past the end of the scale: the first points move nearly one to one, then it
    /// stiffens toward `maximum` points (a rubber band).
    public static func rubberBand(_ excess: Double, maximum: Double = 56) -> Double {
      guard excess > 0 else { return 0 }
      return maximum * (1 - exp(-excess / maximum))
    }

    /// How many points the drag went past the end of the scale (positive both ways), for the rubber band.
    public static func excess(start: Int, dragWidth: Double) -> Double {
      let raw = Double(snap(start)) - (dragWidth / pointsPerStep) * Double(stepMinutes)
      let limit = Double(limitMinutes)
      let over = abs(raw) > limit ? abs(raw) - limit : 0
      return over / Double(stepMinutes) * pointsPerStep
    }
  }

  /// Time of day on a city's clock, which tints its card: who is asleep, up, or at work.
  public enum DayBand: String, CaseIterable {
    case night, morning, work, evening

    /// Working hours are 9:00–18:00; morning 6–9, evening 18–22, night otherwise.
    public init(hour: Int) {
      switch hour {
      case 9..<18: self = .work
      case 6..<9: self = .morning
      case 18..<22: self = .evening
      default: self = .night
      }
    }

    public init(zone: TimeZone, at date: Date) {
      self.init(hour: WorldClock.hourMinute(zone: zone, at: date).hour)
    }
  }

  public static let workStartHour = 9, workEndHour = 18

  /// Whether `date` falls within working hours (9:00–18:00) on the city's clock.
  public static func isWorking(_ zone: TimeZone, at date: Date) -> Bool {
    DayBand(zone: zone, at: date) == .work
  }

  /// The home city's calendar day around `date`: local midnight to the next midnight (23 or 25 hours on DST days).
  public static func day(containing date: Date, in home: TimeZone) -> DateInterval {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = home
    let start = cal.startOfDay(for: date)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return DateInterval(start: start, end: end)
  }

  /// One city's working hours (9–18 on its own clock) that fall inside `window`, across its date changes.
  public static func workIntervals(_ zone: TimeZone, within window: DateInterval) -> [DateInterval]
  {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let first = cal.startOfDay(for: window.start)
    var out: [DateInterval] = []
    for d in -1...2 {
      guard let day = cal.date(byAdding: .day, value: d, to: first),
        let s = cal.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day),
        let e = cal.date(bySettingHour: workEndHour, minute: 0, second: 0, of: day),
        let hit = DateInterval(start: s, end: e).intersection(with: window), hit.duration > 0
      else { continue }
      out.append(hit)
    }
    return out
  }

  /// The hours of the home city's day when every city (home included) is within working hours. Usually one stretch,
  /// empty when they never line up. Times are absolute; show them on any clock.
  public static func overlap(_ zones: [TimeZone], home: TimeZone, on date: Date) -> [DateInterval] {
    let window = day(containing: date, in: home)
    var common = [window]
    for zone in [home] + zones {
      let work = workIntervals(zone, within: window)
      common = common.flatMap { c in
        work.compactMap { w in c.intersection(with: w).flatMap { $0.duration > 0 ? $0 : nil } }
      }
      if common.isEmpty { break }
    }
    return common.sorted { $0.start < $1.start }
  }

  /// "Dallas", "Dallas and Boston", "Dallas, Boston and 1 more".
  public static func nameList(_ names: [String]) -> String {
    switch names.count {
    case 0: ""
    case 1: names[0]
    case 2: names[0] + " and " + names[1]
    default: names[0] + ", " + names[1] + " and \(names.count - 2) more"
    }
  }

  /// "Overlap for Dallas, Boston and 1 more when it's 08:00 in San Jose", or that there is none that day.
  public static func overlapSentence(
    cities: [String], home: String, homeZone: TimeZone, overlap: [DateInterval],
    locale: Locale = .current
  ) -> String {
    let who = nameList(cities)
    guard let first = overlap.first else { return "No working hours overlap for \(who) today" }
    let hm = hourMinute(zone: homeZone, at: first.start)
    let parts = AlarmPlan.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
    let time = parts.time + (parts.suffix.map { " " + $0 } ?? "")
    return "Overlap for \(who) when it's \(time) in \(home)"
  }

  /// "Sat, Oct 18" on the city's calendar.
  public static func dateText(zone: TimeZone, at date: Date, locale: Locale = .current) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = zone
    f.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return f.string(from: date)
  }

  /// The saved cities without the home zone: home is always shown first, on its own.
  public static func others(_ list: [String], home: String) -> [String] {
    list.filter { $0 != home }
  }
}

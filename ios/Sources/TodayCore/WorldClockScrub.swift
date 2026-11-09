import Foundation

extension WorldClock {
  /// Scrubbing moves every city's clock together. A slow drag is exact (one minute per 10 points); the faster the finger,
  /// the more time each point covers, and a release with speed keeps going, slows down and lands on a quarter hour.
  /// The numbers are tuned for: a normal swipe about half a day, a fast flick about two days.
  public enum Scrub {
    public static let stepMinutes = 1
    /// Ten years either way, so the calendar can reach any day it offers (`pickableRange`).
    public static let limitMinutes = 10 * 365 * 24 * 60
    /// Points of horizontal drag per one-minute step at slow speed.
    public static let pointsPerStep: Double = 10

    // MARK: Acceleration

    /// At or below this finger speed (points per second) the drag stays exact.
    public static let fineSpeed: Double = 150
    public static let gainScale = 2.3e-4
    public static let gainExponent = 1.25
    public static let maxMinutesPerPoint: Double = 4

    /// How many minutes one point of drag covers at a finger speed. Never falls as the speed rises.
    public static func minutesPerPoint(speed: Double) -> Double {
      let slow = Double(stepMinutes) / pointsPerStep
      guard speed > fineSpeed else { return slow }
      return min(maxMinutesPerPoint, slow + gainScale * pow(speed - fineSpeed, gainExponent))
    }

    // MARK: Inertia

    /// A release slower than this just stops where it is.
    public static let flickSpeed: Double = 300
    /// The time constant of the slowdown, in seconds.
    public static let coastTimeConstant = 0.25
    /// Where a coast lands: a multiple of this many minutes from now, so the pill reads "11 HOURS 30 MIN".
    public static let coastStepMinutes = 15
    /// One coast goes at most a day; the rest of a long jump belongs to more flicks or the calendar.
    public static let maxCoastMinutes: Double = 24 * 60

    /// The slowdown after a release, in closed form so it is the same at any frame rate.
    public struct Coast: Equatable, Sendable {
      public let start: Double
      public let target: Int

      public func position(elapsed: TimeInterval) -> Double {
        start + (Double(target) - start) * (1 - exp(-elapsed / coastTimeConstant))
      }

      public func isDone(elapsed: TimeInterval) -> Bool {
        abs(Double(target) - position(elapsed: elapsed)) < 0.5
      }
    }

    /// The scrub as a value: what the touch, the finger and the clock of the display do to the offset.
    public struct Motion: Equatable, Sendable {
      /// Minutes away from now; 0 = now.
      public private(set) var offset: Int
      /// The time is moving too fast to read; the cards drop their per-step animations.
      public private(set) var isFast = false
      public private(set) var coast: Coast?
      private var dragStart: Int
      private var travel = 0.0

      public init(offset: Int = 0) {
        self.offset = offset
        dragStart = offset
      }

      public var isCoasting: Bool { coast != nil }

      private mutating func rest() {
        coast = nil
        isFast = false
        dragStart = offset
        travel = 0
      }

      /// A finger came down: a coast stops at once, where it is.
      public mutating func touchDown() { rest() }

      /// The calendar or the pill: go straight to an offset.
      public mutating func jump(to minutes: Int) {
        offset = clamp(minutes)
        rest()
      }

      /// The finger moved by `points` (positive to the right) at `speed` points per second.
      /// Dragging left moves time forward, dragging right moves it backward.
      public mutating func drag(points: Double, speed: Double) {
        coast = nil
        isFast = speed > fineSpeed
        travel -= points * minutesPerPoint(speed: speed)
        // Past the end of the scale the travel stops winding up, so turning back answers at once.
        travel = min(
          max(travel, Double(-limitMinutes - dragStart)), Double(limitMinutes - dragStart))
        offset = clamp(dragStart + Int(travel.rounded(.towardZero)))
      }

      /// The finger lifted at `velocity` points per second (positive to the right).
      public mutating func release(velocity: Double) {
        rest()
        let speed = abs(velocity)
        guard speed > flickSpeed else { return }
        let direction = velocity < 0 ? 1.0 : -1.0
        let reach = min(maxCoastMinutes, speed * minutesPerPoint(speed: speed) * coastTimeConstant)
        let target = landing(from: offset, direction: direction, reach: reach)
        guard target != offset else { return }
        coast = Coast(start: Double(offset), target: target)
        isFast = true
      }

      /// Moves a coast on to `elapsed` seconds after the release.
      public mutating func advance(elapsed: TimeInterval) {
        guard let coast else { return }
        if coast.isDone(elapsed: elapsed) {
          offset = clamp(coast.target)
          rest()
        } else {
          offset = clamp(Int(coast.position(elapsed: elapsed).rounded()))
        }
      }
    }

    /// The landing step at or past where a coast would naturally end, never behind where it started.
    static func landing(from offset: Int, direction: Double, reach: Double) -> Int {
      let step = Double(coastStepMinutes)
      let here = Double(offset)
      var target = ((here + direction * reach) / step).rounded() * step
      if (target - here) * direction <= 0 { target += direction * step }
      return clamp(Int(target))
    }

    static func clamp(_ minutes: Int) -> Int { min(limitMinutes, max(-limitMinutes, minutes)) }

    // MARK: Dates

    /// The moment the cards show: now plus the offset. Minutes are kept (18:50 minus 15 hours reads 03:50), as in Overlap.
    public static func date(now: Date, offset minutes: Int) -> Date {
      now.addingTimeInterval(Double(minutes) * 60)
    }

    /// The days the calendar offers: all of them reachable by `offset(picking:...)` without hitting the end of the scale.
    public static func pickableRange(now: Date) -> ClosedRange<Date> {
      let edge = Double(limitMinutes - 2 * 24 * 60) * 60
      return now.addingTimeInterval(-edge)...now.addingTimeInterval(edge)
    }

    /// The offset that shows `day` (in `calendar`, whose time zone is the home zone) at the time of day now shown there.
    /// Calendar arithmetic, so a day with a daylight saving change is right; a time that does not exist that day
    /// moves to the next one that does, and a time that happens twice takes the first.
    public static func offset(picking day: Date, shown: Date, now: Date, calendar: Calendar) -> Int
    {
      let time = calendar.dateComponents([.hour, .minute, .second], from: shown)
      let target =
        calendar.date(
          bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0,
          of: calendar.startOfDay(for: day), matchingPolicy: .nextTimePreservingSmallerComponents,
          repeatedTimePolicy: .first, direction: .forward) ?? day
      return clamp(Int((target.timeIntervalSince(now) / 60).rounded()))
    }

    // MARK: Pill

    /// The pill under the cities, in two parts so the keyword can be bold: ("", "NOW"), ("15 HOURS BEFORE ", "NOW"),
    /// ("1 HOUR 15 MIN AFTER ", "NOW"), ("3 DAYS 4 HOURS AFTER ", "NOW").
    public static func pillParts(_ minutes: Int) -> (lead: String, keyword: String) {
      guard minutes != 0 else { return ("", "NOW") }
      return (span(abs(minutes)) + (minutes > 0 ? " AFTER " : " BEFORE "), "NOW")
    }

    /// Under a day: hours and minutes. Then days and hours, days alone from two weeks, years and days from a year.
    private static func span(_ minutes: Int) -> String {
      func count(_ n: Int, _ unit: String) -> String? {
        n == 0 ? nil : "\(n) \(unit)" + (n == 1 ? "" : "S")
      }
      let hours = minutes / 60
      let days = hours / 24
      let parts: [String?]
      if days == 0 {
        parts = [count(hours, "HOUR"), minutes % 60 == 0 ? nil : "\(minutes % 60) MIN"]
      } else if days < 14 {
        parts = [count(days, "DAY"), count(hours % 24, "HOUR")]
      } else if days < 365 {
        parts = [count(days, "DAY")]
      } else {
        parts = [count(days / 365, "YEAR"), count(days % 365, "DAY")]
      }
      return parts.compactMap { $0 }.joined(separator: " ")
    }

    /// The pill as one line: "NOW", "15 HOURS BEFORE NOW".
    public static func pillText(_ minutes: Int) -> String {
      let p = pillParts(minutes)
      return p.lead + p.keyword
    }
  }

  /// The card texts that need a `DateFormatter`, cached: a scrub redraws every card on every frame, and building a
  /// formatter each time is the slowest thing in it. Owned by the view, used from the main thread only.
  public final class CardTexts {
    private struct DayKey: Hashable {
      let zone: String
      let day: Int
    }

    private var locale: Locale?
    private var twelveHour = false
    private var symbols = (am: "AM", pm: "PM")
    private var formatters: [String: DateFormatter] = [:]
    private var dates: [DayKey: String] = [:]

    public init() {}

    private func use(_ locale: Locale) {
      guard self.locale != locale else { return }
      self.locale = locale
      formatters = [:]
      dates = [:]
      let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
      twelveHour = pattern.contains("a")
      let f = DateFormatter()
      f.locale = locale
      symbols = (f.amSymbol, f.pmSymbol)
    }

    /// The same text as `WorldClock.longDate`.
    public func longDate(zone: TimeZone, at date: Date, locale: Locale) -> String {
      use(locale)
      let offset = Double(zone.secondsFromGMT(for: date))
      let key = DayKey(
        zone: zone.identifier,
        day: Int(((date.timeIntervalSince1970 + offset) / 86_400).rounded(.down)))
      if let text = dates[key] { return text }
      let formatter =
        formatters[zone.identifier] ?? WorldClock.longDateFormatter(zone: zone, locale: locale)
      formatters[zone.identifier] = formatter
      let text = formatter.string(from: date).uppercased(with: locale)
      if dates.count >= 512 { dates = [:] }
      dates[key] = text
      return text
    }

    /// The same parts as `AlarmPlan.timeParts`.
    public func timeParts(hour: Int, minute: Int, locale: Locale) -> (time: String, suffix: String?)
    {
      use(locale)
      let mm = String(format: "%02d", minute)
      guard twelveHour else { return (String(format: "%02d:", hour) + mm, nil) }
      return ("\(hour % 12 == 0 ? 12 : hour % 12):" + mm, hour < 12 ? symbols.am : symbols.pm)
    }
  }
}

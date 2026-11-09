import Foundation

/// The look of World Clock as plain numbers (no SwiftUI), so it can be tested: the card colors by local time of day,
/// the "+2" and "SATURDAY, OCTOBER 17" texts, the sentence under the graph and the waves behind it.
/// Measured from Overlap's screens; see docs/design/world-clock.md.
extension WorldClock {
  public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double  // 0...255
    public init(_ r: Double, _ g: Double, _ b: Double) {
      self.r = r
      self.g = g
      self.b = b
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
      RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }
  }

  /// A card's colors: a left-to-right gradient. Inside working hours (9:00–18:00 there) it is one flat green.
  public struct CardColors: Equatable {
    public var leading: RGB
    public var trailing: RGB
    public var isGood: Bool

    public init(leading: RGB, trailing: RGB, isGood: Bool) {
      self.leading = leading
      self.trailing = trailing
      self.isGood = isGood
    }
  }

  public enum Look {
    public static let green = RGB(73, 162, 125)  // #49A27D
    public static let night = RGB(26, 16, 59)  // #1A103B
    public static let day = RGB(33, 72, 114)  // #214872, the brightest blue
    public static let pill = RGB(24, 30, 37)  // #181E25
    /// The gradient reads this many minutes before and after the shown time.
    public static let spreadMinutes = 20.0

    /// Colors by minute of the local day, sampled from the screens (deep night, dawn brightening to day blue, day blue
    /// fading after 18:00 into night). Between stops the colors are mixed linearly. Hours 9–18 are green, not here.
    private static let stops: [(minute: Double, color: RGB)] = [
      (0, night), (2 * 60 + 40, night), (3 * 60 + 30, RGB(26, 20, 63)),
      (3 * 60 + 50, RGB(26, 23, 65)),
      (4 * 60 + 10, RGB(26, 26, 69)), (5 * 60 + 30, RGB(28, 48, 92)),
      (5 * 60 + 50, RGB(28, 51, 95)),
      (6 * 60 + 10, RGB(29, 54, 99)), (6 * 60 + 30, RGB(31, 63, 107)),
      (6 * 60 + 50, RGB(32, 66, 111)),
      (7 * 60 + 10, RGB(33, 69, 114)), (8 * 60, day), (18 * 60, day),
      (18 * 60 + 20, RGB(29, 58, 102)),
      (18 * 60 + 40, RGB(27, 46, 90)), (18 * 60 + 50, RGB(27, 42, 86)),
      (19 * 60 + 10, RGB(27, 39, 83)),
      (20 * 60, RGB(26, 23, 66)), (20 * 60 + 20, RGB(26, 20, 64)), (20 * 60 + 40, RGB(26, 17, 61)),
      (21 * 60, night), (24 * 60, night),
    ]

    /// The blue-to-indigo color at a minute of the day (0..<1440, clamped).
    public static func color(atMinute minute: Double) -> RGB {
      let m = min(max(minute, 0), 24 * 60)
      guard let i = stops.firstIndex(where: { $0.minute >= m }), i > 0 else {
        return stops[0].color
      }
      let (a, b) = (stops[i - 1], stops[i])
      return RGB.mix(a.color, b.color, (m - a.minute) / (b.minute - a.minute))
    }

    /// The card colors at a local hour and minute.
    public static func card(hour: Int, minute: Int) -> CardColors {
      if hour >= WorldClock.workStartHour && hour < WorldClock.workEndHour {
        return CardColors(leading: green, trailing: green, isGood: true)
      }
      let m = Double(hour * 60 + minute)
      return CardColors(
        leading: color(atMinute: m - spreadMinutes), trailing: color(atMinute: m + spreadMinutes),
        isGood: false)
    }

    public static func card(zone: TimeZone, at date: Date) -> CardColors {
      let hm = WorldClock.hourMinute(zone: zone, at: date)
      return card(hour: hm.hour, minute: hm.minute)
    }
  }

  /// "+2", "-8", "+5:30", "+0": the city's clock minus the home clock, at that moment (follows daylight saving time).
  public static func offsetBadge(zone: TimeZone, home: TimeZone, at date: Date) -> String {
    let seconds = zone.secondsFromGMT(for: date) - home.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "-" : "+"
    let minutes = abs(seconds) / 60
    let h = minutes / 60
    let m = minutes % 60
    return m == 0 ? "\(sign)\(h)" : "\(sign)\(h):" + String(format: "%02d", m)
  }

  /// "UTC+8", "UTC-5", "UTC+5:30": a zone's difference to UTC at that moment, for the city picker.
  public static func utcOffsetText(zone: TimeZone, at date: Date) -> String {
    let seconds = zone.secondsFromGMT(for: date)
    let minutes = abs(seconds) / 60
    let h = minutes / 60
    let m = minutes % 60
    let sign = seconds < 0 ? "-" : "+"
    return "UTC"
      + (seconds == 0 ? "" : m == 0 ? "\(sign)\(h)" : "\(sign)\(h):" + String(format: "%02d", m))
  }

  /// "SATURDAY, OCTOBER 17" on the city's calendar, in the reader's language.
  public static func longDate(zone: TimeZone, at date: Date, locale: Locale = .current) -> String {
    longDateFormatter(zone: zone, locale: locale).string(from: date).uppercased(with: locale)
  }

  static func longDateFormatter(zone: TimeZone, locale: Locale) -> DateFormatter {
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = zone
    f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    return f
  }

  // MARK: Sentence under the graph

  public struct Segment: Equatable {
    public let text: String
    public let bold: Bool

    public init(text: String, bold: Bool) {
      self.text = text
      self.bold = bold
    }
  }

  /// "Overlap for Dallas, Boston, Aba and 1 more, when it was 04:50 in San Jose" as pieces: bold names and time, light
  /// words. Three names at most, the rest as "and N more". `offset` (minutes from now) picks was / is / will be.
  public static func overlapSegments(cities: [String], home: String, time: String, offset: Int)
    -> [Segment]
  {
    guard !cities.isEmpty else {
      return [Segment(text: "Add a city to see when your hours overlap", bold: false)]
    }
    var names: String
    var rest = ""
    switch cities.count {
    case 1: names = cities[0]
    case 2: names = cities[0] + " and " + cities[1]
    case 3: names = cities[0] + ", " + cities[1] + " and " + cities[2]
    default:
      names = cities.prefix(3).joined(separator: ", ")
      rest = " and \(cities.count - 3) more"
    }
    let verb = offset == 0 ? "is" : (offset < 0 ? "was" : "will be")
    return [
      Segment(text: "Overlap", bold: true), Segment(text: " for ", bold: false),
      Segment(text: names, bold: true), Segment(text: rest + ", when it \(verb) ", bold: false),
      Segment(text: time, bold: true), Segment(text: " in ", bold: false),
      Segment(text: home, bold: true),
    ]
  }

  // MARK: Waves

  /// The waves behind the graph, each a list of heights from 0 to 1 over `hours` hours from `start`:
  /// the front one counts the cities within working hours (9–18), the two behind count those awake (7–22 and 6–23)
  /// and sit above it. Heights are the share of all cities, smoothed so the edges roll instead of step.
  public static func waves(
    zones: [TimeZone], start: Date, hours: Double = 5, samples: Int = 61,
    smoothingMinutes: Double = 22
  ) -> [[Double]] {
    guard !zones.isEmpty, samples > 1 else { return [[], [], []] }
    let step = hours * 3600 / Double(samples - 1)
    // Sample wider than the window so the smoothing has data at both ends.
    let pad = Int((smoothingMinutes * 60 * 3 / step).rounded(.up))
    // Local time of day (in hours) of every city at every sample, worked out once for the three waves.
    let localHours: [[Double]] = (-pad..<(samples + pad)).map { i in
      let t = start.addingTimeInterval(Double(i) * step)
      return zones.map { z in
        let hm = hourMinute(zone: z, at: t)
        return Double(hm.hour) + Double(hm.minute) / 60
      }
    }
    func counts(_ from: Int, _ to: Int) -> [Double] {
      localHours.map { row in
        Double(row.filter { $0 >= Double(from) && $0 < Double(to) }.count) / Double(zones.count)
      }
    }
    let sigma = smoothingMinutes * 60 / step
    func smooth(_ values: [Double]) -> [Double] {
      let radius = pad
      let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
      let total = kernel.reduce(0, +)
      return (0..<samples).map { i in
        var acc = 0.0
        for k in -radius...radius { acc += values[i + pad + k] * kernel[k + radius] }
        return acc / total
      }
    }
    let front = smooth(counts(workStartHour, workEndHour))
    // Back waves never sit below the front one.
    let mid = zip(smooth(counts(7, 22)), front).map { max($0, $1) }
    let back = zip(smooth(counts(6, 23)), mid).map { max($0, $1) }
    return [front, mid, back]
  }
}

import Foundation

/// The three parts of a day the Today timeline groups its rows into.
public enum DayPart: Int, CaseIterable, Sendable {
  case morning, afternoon, evening

  /// The whole hours where afternoon and evening begin. Morning always opens the day and every part keeps
  /// at least an hour, so the three stay in order; a pair that breaks this is the standard one.
  public struct Boundaries: Equatable, Sendable {
    public let afternoon: Int
    public let evening: Int
    public static let standard = Boundaries(afternoon: 12, evening: 18)

    public init(afternoon: Int, evening: Int) {
      let valid = afternoon >= 1 && afternoon < evening && evening <= 23
      self.afternoon = valid ? afternoon : 12
      self.evening = valid ? evening : 18
    }

    /// The hours afternoon can start at while evening stays where it is.
    public var afternoonChoices: [Int] { Array(1..<evening) }
    /// The hours evening can start at while afternoon stays where it is.
    public var eveningChoices: [Int] { Array((afternoon + 1)...23) }
  }

  /// Before afternoon, afternoon up to evening, evening onward (12:00 and 18:00 unless Settings says
  /// otherwise). An item belongs to the part of its start, so an event crossing a boundary stays where it
  /// starts; one that began on an earlier day opens the morning.
  public static func of(
    _ start: Date, day: Date, calendar: Calendar, boundaries: Boundaries = .standard
  ) -> DayPart {
    guard start >= calendar.startOfDay(for: day) else { return .morning }
    let hour = calendar.component(.hour, from: start)
    if hour < boundaries.afternoon { return .morning }
    return hour < boundaries.evening ? .afternoon : .evening
  }

  /// From this part's first moment up to the next part's, or the end of the day.
  public func bounds(
    day: Date, calendar: Calendar, boundaries: Boundaries = .standard
  ) -> DateInterval? {
    guard let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
    func at(_ hour: Int) -> Date? {
      calendar.date(bySettingHour: hour, minute: 0, second: 0, of: interval.start)
    }
    let start: Date?
    let end: Date?
    switch self {
    case .morning: (start, end) = (interval.start, at(boundaries.afternoon))
    case .afternoon: (start, end) = (at(boundaries.afternoon), at(boundaries.evening))
    case .evening: (start, end) = (at(boundaries.evening), interval.end)
    }
    guard let start, let end, start < end else { return nil }
    return DateInterval(start: start, end: end)
  }

  /// Where an item dropped into this part lands when nothing else in the part says otherwise: 09:00, 14:00
  /// or 19:00, or the nearest whole hour still inside the part when Settings moved its boundaries.
  public func usualTime(
    day: Date, calendar: Calendar, boundaries: Boundaries = .standard
  ) -> Date? {
    let hour: Int
    switch self {
    case .morning: hour = min(9, boundaries.afternoon - 1)
    case .afternoon: hour = min(max(14, boundaries.afternoon), boundaries.evening - 1)
    case .evening: hour = max(19, boundaries.evening)
    }
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
  }

  /// A part's rows, card label and card end, in day order. A part needs one planned item to earn a card:
  /// free time and the Now line alone never invent one, they stay loose rows at their place in the day.
  /// `showsEmptyParts` is for a drag in progress: a part with nothing in it shows an empty card to drop into.
  /// A part in `collapsed` that holds a planned item becomes one collapsed row naming its first planned
  /// item and how many planned items follow it; expanding it shows every held row again, nothing is dropped.
  public static func rows<Item>(
    _ items: [Item], day: Date, calendar: Calendar, boundaries: Boundaries = .standard,
    start: (Item) -> Date, isPlanned: (Item) -> Bool, showsEmptyParts: Bool = false,
    collapsed: Set<DayPart> = []
  ) -> [DayPartRow<Item>] {
    var parts: [DayPart: [Item]] = [:]
    for item in items {
      parts[of(start(item), day: day, calendar: calendar, boundaries: boundaries), default: []]
        .append(item)
    }
    return allCases.flatMap { part -> [DayPartRow<Item>] in
      let held = parts[part] ?? []
      if held.isEmpty, showsEmptyParts { return [.label(part), .emptyPart(part), .cardEnd(part)] }
      guard held.contains(where: isPlanned) else {
        return held.map { .item($0, card: nil, closesCard: false) }
      }
      if collapsed.contains(part), !showsEmptyParts {
        let preview = DayPartDisclosure.preview(held, isPlanned: isPlanned)
        return [
          .collapsed(part, preview: preview.first, extraCount: preview.extraCount),
          .cardEnd(part),
        ]
      }
      return [.label(part)]
        + held.enumerated().map { index, item in
          .item(item, card: part, closesCard: index == held.count - 1)
        } + [.cardEnd(part)]
    }
  }
}

/// Which day parts the Today timeline shows open. The caller freezes `anchorNow` when a day is shown, so
/// crossing a part boundary later never opens or closes a part under a scrolling user; a manual choice for
/// that day and part then wins over the default for as long as the caller keeps it.
public enum DayPartDisclosure {
  /// The part `anchorNow` falls in on `day`; only this part opens by default on today.
  public static func currentPart(
    anchorNow: Date, day: Date, calendar: Calendar, boundaries: DayPart.Boundaries = .standard
  ) -> DayPart {
    DayPart.of(anchorNow, day: day, calendar: calendar, boundaries: boundaries)
  }

  /// A day other than today has no current part, so every part opens by default and no content hides.
  /// On today only the current part opens, unless the user chose otherwise for this day and part.
  public static func isExpanded(
    _ part: DayPart, viewingToday: Bool, anchorNow: Date, day: Date, calendar: Calendar,
    boundaries: DayPart.Boundaries = .standard, override: Bool?
  ) -> Bool {
    if let override { return override }
    guard viewingToday else { return true }
    return part
      == currentPart(anchorNow: anchorNow, day: day, calendar: calendar, boundaries: boundaries)
  }

  /// Stable identity of one manual choice: the viewed day plus the part.
  public static func overrideKey(day: Date, part: DayPart, calendar: Calendar) -> String {
    "\(Int(calendar.startOfDay(for: day).timeIntervalSince1970))|\(part.rawValue)"
  }

  public static func collapsedParts(
    viewingToday: Bool, anchorNow: Date, day: Date, calendar: Calendar,
    boundaries: DayPart.Boundaries = .standard, overrides: [String: Bool]
  ) -> Set<DayPart> {
    Set(
      DayPart.allCases.filter {
        !isExpanded(
          $0, viewingToday: viewingToday, anchorNow: anchorNow, day: day, calendar: calendar,
          boundaries: boundaries,
          override: overrides[overrideKey(day: day, part: $0, calendar: calendar)])
      })
  }

  /// What a collapsed part still shows: its first planned (timed) item in timeline order, plus how many
  /// planned items follow it. Free time and the Now line are not items and never count, so
  /// `1 + extraCount` always equals the planned rows shown once the part is expanded.
  public struct Preview<Item> {
    public let first: Item?
    public let extraCount: Int
    public let plannedCount: Int
  }

  public static func preview<Item>(_ items: [Item], isPlanned: (Item) -> Bool) -> Preview<Item> {
    let planned = items.filter(isPlanned)
    return Preview(
      first: planned.first, extraCount: max(0, planned.count - 1), plannedCount: planned.count)
  }
}

/// One List row of the sectioned timeline. `card` is the part whose card holds the item, nil outside any
/// card; `closesCard` marks the card's last item, which draws the bottom corners.
public enum DayPartRow<Item> {
  case label(DayPart)
  /// A collapsed part: its first planned item still shows, `extraCount` planned items follow it.
  case collapsed(DayPart, preview: Item?, extraCount: Int)
  case item(Item, card: DayPart?, closesCard: Bool)
  /// A part with no items, shown only as a drop target during a drag.
  case emptyPart(DayPart)
  case cardEnd(DayPart)
}

extension DayPartRow: Identifiable where Item: Identifiable {
  /// An item keeps its own identity wherever it lands, so a move between parts stays one row.
  public var id: AnyHashable {
    switch self {
    case .label(let part): "dayPart.label.\(part.rawValue)"
    case .collapsed(let part, _, _): "dayPart.collapsed.\(part.rawValue)"
    case .item(let item, _, _): AnyHashable(item.id)
    case .emptyPart(let part): "dayPart.empty.\(part.rawValue)"
    case .cardEnd(let part): "dayPart.end.\(part.rawValue)"
    }
  }
}

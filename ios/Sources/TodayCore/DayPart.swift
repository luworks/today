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

  /// A part's rows, card label and card end, in day order. A part needs one planned item to earn a card:
  /// free time and the Now line alone never invent one, they stay loose rows at their place in the day.
  public static func rows<Item>(
    _ items: [Item], day: Date, calendar: Calendar, boundaries: Boundaries = .standard,
    start: (Item) -> Date, isPlanned: (Item) -> Bool
  ) -> [DayPartRow<Item>] {
    var parts: [DayPart: [Item]] = [:]
    for item in items {
      parts[of(start(item), day: day, calendar: calendar, boundaries: boundaries), default: []]
        .append(item)
    }
    return allCases.flatMap { part -> [DayPartRow<Item>] in
      let held = parts[part] ?? []
      guard held.contains(where: isPlanned) else {
        return held.map { .item($0, card: nil, closesCard: false) }
      }
      return [.label(part)]
        + held.enumerated().map { index, item in
          .item(item, card: part, closesCard: index == held.count - 1)
        } + [.cardEnd(part)]
    }
  }
}

/// One List row of the sectioned timeline. `card` is the part whose card holds the item, nil outside any
/// card; `closesCard` marks the card's last item, which draws the bottom corners.
public enum DayPartRow<Item> {
  case label(DayPart)
  case item(Item, card: DayPart?, closesCard: Bool)
  case cardEnd(DayPart)
}

extension DayPartRow: Identifiable where Item: Identifiable {
  /// An item keeps its own identity wherever it lands, so a move between parts stays one row.
  public var id: AnyHashable {
    switch self {
    case .label(let part): "dayPart.label.\(part.rawValue)"
    case .item(let item, _, _): AnyHashable(item.id)
    case .cardEnd(let part): "dayPart.end.\(part.rawValue)"
    }
  }
}

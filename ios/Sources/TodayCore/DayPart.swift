import Foundation

/// The three parts of a day the Today timeline groups its rows into.
public enum DayPart: Int, CaseIterable, Sendable {
  case morning, afternoon, evening

  /// Before 12:00, 12:00 up to 18:00, 18:00 onward. An item belongs to the part of its start, so an
  /// event crossing a boundary stays where it starts; one that began on an earlier day opens the morning.
  public static func of(_ start: Date, day: Date, calendar: Calendar) -> DayPart {
    guard start >= calendar.startOfDay(for: day) else { return .morning }
    switch calendar.component(.hour, from: start) {
    case ..<12: return .morning
    case ..<18: return .afternoon
    default: return .evening
    }
  }

  /// A part's rows, card label and card end, in day order. A part needs one planned item to earn a card:
  /// free time and the Now line alone never invent one, they stay loose rows at their place in the day.
  public static func rows<Item>(
    _ items: [Item], day: Date, calendar: Calendar, start: (Item) -> Date,
    isPlanned: (Item) -> Bool
  ) -> [DayPartRow<Item>] {
    var parts: [DayPart: [Item]] = [:]
    for item in items {
      parts[of(start(item), day: day, calendar: calendar), default: []].append(item)
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

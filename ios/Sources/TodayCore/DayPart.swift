import Foundation

public enum DayPart: Int, CaseIterable, Sendable {
  case morning, afternoon, evening

  public static func of(_ start: Date, day: Date, calendar: Calendar) -> DayPart {
    guard start >= calendar.startOfDay(for: day) else { return .morning }
    let hour = calendar.component(.hour, from: start)
    if hour < 12 { return .morning }
    return hour < 18 ? .afternoon : .evening
  }

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

public enum DayPartRow<Item> {
  case label(DayPart)
  case item(Item, card: DayPart?, closesCard: Bool)
  case cardEnd(DayPart)
}

extension DayPartRow: Identifiable where Item: Identifiable {
  public var id: AnyHashable {
    switch self {
    case .label(let part): "dayPart.label.\(part.rawValue)"
    case .item(let item, _, _): AnyHashable(item.id)
    case .cardEnd(let part): "dayPart.end.\(part.rawValue)"
    }
  }
}

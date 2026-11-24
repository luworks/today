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
    isPlanned: (Item) -> Bool, isOpen: (DayPart) -> Bool = { _ in true },
    keepsWhenClosed: (Item) -> Bool = { _ in false }
  ) -> [DayPartRow<Item>] {
    var parts: [DayPart: [Item]] = [:]
    for item in items {
      parts[of(start(item), day: day, calendar: calendar), default: []].append(item)
    }
    return allCases.flatMap { part -> [DayPartRow<Item>] in
      let held = parts[part] ?? []
      let count = held.count(where: isPlanned)
      guard count > 0 else { return held.map { .item($0, part: nil) } }
      let open = isOpen(part)
      let shown = open ? held : held.filter(keepsWhenClosed)
      return [.label(part, count: count, isOpen: open)] + shown.map { .item($0, part: part) }
    }
  }
}

public enum DayPartRow<Item> {
  case label(DayPart, count: Int, isOpen: Bool)
  case item(Item, part: DayPart?)
}

extension DayPartRow: Identifiable where Item: Identifiable {
  public var id: AnyHashable {
    switch self {
    case .label(let part, _, _): "dayPart.label.\(part.rawValue)"
    case .item(let item, _): AnyHashable(item.id)
    }
  }
}

public struct DayPartDisclosure: Equatable, Sendable {
  private var choices: [Date: [DayPart: Bool]] = [:]

  public init() {}

  public func isOpen(_ part: DayPart, day: Date, entry: Date, calendar: Calendar) -> Bool {
    if let choice = choices[calendar.startOfDay(for: day)]?[part] { return choice }
    guard calendar.isDate(day, inSameDayAs: entry) else { return true }
    return part.rawValue >= DayPart.of(entry, day: day, calendar: calendar).rawValue
  }

  public mutating func set(_ part: DayPart, open: Bool, day: Date, calendar: Calendar) {
    choices[calendar.startOfDay(for: day), default: [:]][part] = open
  }

  public mutating func toggle(_ part: DayPart, day: Date, entry: Date, calendar: Calendar) {
    set(
      part, open: !isOpen(part, day: day, entry: entry, calendar: calendar), day: day,
      calendar: calendar)
  }
}

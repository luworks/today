import Foundation

public enum GapFit {
  public static let unstatedMinutes = 25

  public struct Reminder: Equatable {
    public var minutes: Int
    public var due: Date?
    public var dueHasTime: Bool
    public var repeats: Bool
    public var flagged: Bool

    public init(
      minutes: Int, due: Date?, dueHasTime: Bool, repeats: Bool = false, flagged: Bool = false
    ) {
      self.minutes = minutes
      self.due = due
      self.dueHasTime = dueHasTime
      self.repeats = repeats
      self.flagged = flagged
    }

    public var statedMinutes: Int? {
      minutes > 0 && minutes != GapFit.unstatedMinutes ? minutes : nil
    }
  }

  public enum Fit: Equatable { case fits, unknown }

  public struct Candidate: Equatable {
    public let index: Int
    public let fit: Fit
  }

  public struct Result: Equatable {
    public let start: Date
    public let candidates: [Candidate]
    public let tooLong: Int
  }

  public static func start(of gap: DateInterval, now: Date, calendar: Calendar = .current)
    -> Date?
  {
    let earliest = max(gap.start, now)
    let minute = calendar.dateInterval(of: .minute, for: earliest)?.start ?? earliest
    let start = minute < earliest ? minute.addingTimeInterval(60) : minute
    return start < gap.end ? start : nil
  }

  public static func candidates(
    for gap: DateInterval, reminders: [Reminder], now: Date, horizonDays: Int = 7,
    limit: Int = 6, calendar: Calendar = .current
  ) -> Result? {
    guard let start = start(of: gap, now: now, calendar: calendar) else { return nil }
    let room = Int(gap.end.timeIntervalSince(start) / 60)
    let today = calendar.startOfDay(for: now)
    let horizon =
      calendar.date(
        byAdding: .day, value: horizonDays + 1, to: calendar.startOfDay(for: start)) ?? start
    var tooLong = 0
    var picked: [(index: Int, fit: Fit, rank: (Int, Int, Date, Int))] = []
    for (index, r) in reminders.enumerated() where !r.repeats {
      let overdue: Bool
      if let due = r.due {
        if r.dueHasTime && due == start { continue }
        overdue = r.dueHasTime ? due < now : calendar.startOfDay(for: due) < today
        if !overdue {
          let deadline =
            r.dueHasTime
            ? due
            : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due)) ?? due
          if start.addingTimeInterval(TimeInterval((r.statedMinutes ?? 0) * 60)) > deadline
            || start >= deadline
          {
            continue
          }
          if due >= horizon { continue }
        }
      } else {
        overdue = false
      }
      let fit: Fit
      if let need = r.statedMinutes {
        guard need <= room else {
          tooLong += 1
          continue
        }
        fit = .fits
      } else {
        fit = .unknown
      }
      let rank = (
        fit == .fits ? 0 : 1, overdue ? 0 : (r.due == nil ? 2 : 1),
        r.due ?? .distantFuture, r.flagged ? 0 : 1
      )
      picked.append((index, fit, rank))
    }
    picked.sort { a, b in
      if a.rank.0 != b.rank.0 { return a.rank.0 < b.rank.0 }
      if a.rank.1 != b.rank.1 { return a.rank.1 < b.rank.1 }
      if a.rank.2 != b.rank.2 { return a.rank.2 < b.rank.2 }
      if a.rank.3 != b.rank.3 { return a.rank.3 < b.rank.3 }
      return a.index < b.index
    }
    return Result(
      start: start,
      candidates: picked.prefix(limit).map { Candidate(index: $0.index, fit: $0.fit) },
      tooLong: tooLong)
  }

  public struct Conclusion: Equatable {
    public enum Kind: Equatable {
      case fits(index: Int, minutes: Int)
      case tooLong(index: Int, minutes: Int)
      case due(count: Int, freeMinutes: Int)
    }
    public let kind: Kind
    public let opening: DateInterval?

    public func text(title: (Int) -> String, time: (Date) -> String) -> String {
      switch kind {
      case .fits(let index, let minutes):
        return "“\(title(index))” needs \(DurationLabel.text(minutes: minutes))"
          + (opening.map { " · fits at " + time($0.start) } ?? "")
      case .tooLong(let index, let minutes):
        return "“\(title(index))” needs \(DurationLabel.text(minutes: minutes))"
          + " · no opening that long left today"
      case .due(let count, let free):
        let head = "\(count) due today"
        guard let opening, free > 0 else { return head + " · no free time left today" }
        return head + " · \(DurationLabel.text(minutes: free)) free, next at " + time(opening.start)
      }
    }
  }

  public static func conclusion(
    reminders: [Reminder], gaps: [DateInterval], now: Date, calendar: Calendar = .current
  ) -> Conclusion? {
    let due = reminders.indices.filter { i in
      let r = reminders[i]
      guard !r.repeats, !r.dueHasTime, let d = r.due else { return false }
      return calendar.isDate(d, inSameDayAs: now)
    }
    guard !due.isEmpty else { return nil }
    let open = gaps.filter { $0.end > now }.sorted { $0.start < $1.start }
    if let index = due.first(where: { reminders[$0].statedMinutes != nil }),
      let need = reminders[index].statedMinutes
    {
      if let opening = open.first(where: { $0.duration >= TimeInterval(need * 60) }) {
        return Conclusion(kind: .fits(index: index, minutes: need), opening: opening)
      }
      return Conclusion(kind: .tooLong(index: index, minutes: need), opening: nil)
    }
    let free = open.reduce(0) { $0 + Int($1.duration / 60) }
    return Conclusion(kind: .due(count: due.count, freeMinutes: free), opening: open.first)
  }
}

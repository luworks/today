import Foundation

public struct ChatMessage: Identifiable, Equatable, Codable {
  public enum Role: String, Codable { case user, ai }
  public var id = UUID()
  public let role: Role
  public let text: String
  /// Optional for backward-compatible decoding of older text-only chats.
  public var timestamp: Date? = .now
  /// An AI answer in the model's own words (worth copying). nil for the app's own status sentences
  /// and for older chats. Optional so older chats decode.
  public var carriesContent: Bool?

  /// One of the app's own status sentences (see `MessageCopy`): no Copy button under it.
  public var isTemplate: Bool {
    MessageCopy.isTemplate(isUser: role == .user, content: carriesContent == true)
  }

  public init(
    id: UUID = UUID(), role: Role, text: String, timestamp: Date? = .now,
    carriesContent: Bool? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.carriesContent = carriesContent
  }
}

// Pure logic with no SwiftData/SwiftUI, so it can be unit-tested with `swift test` (see ios/Eval).

/// Past AI conversations, grouped like ChatGPT's history: Today, Yesterday, Previous 7 Days, Older.
public enum ConversationBucket: Int, CaseIterable, Comparable {
  case today, yesterday, previous7Days, older

  public var title: String {
    switch self {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .previous7Days: "Previous 7 Days"
    case .older: "Older"
    }
  }

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  /// Calendar days decide, not hours: 00:05 today is "Today" and 23:55 yesterday is "Yesterday".
  /// "Previous 7 Days" covers the days from 2 to 7 days ago.
  public static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> Self {
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch days {
    case ..<1: return .today  // today, or a clock that moved backwards
    case 1: return .yesterday
    case 2...7: return .previous7Days
    default: return .older
    }
  }
}

public enum ConversationHistory {
  /// Newest first, split into non-empty buckets in display order. Items with equal dates keep their input order.
  public static func group<T>(
    _ items: [T], date: (T) -> Date, now: Date = .now, calendar: Calendar = .current
  )
    -> [(bucket: ConversationBucket, items: [T])]
  {
    let sorted = items.enumerated().sorted { a, b in
      let (da, db) = (date(a.element), date(b.element))
      return da == db ? a.offset < b.offset : da > db
    }.map(\.element)
    var out: [(bucket: ConversationBucket, items: [T])] = []
    for bucket in ConversationBucket.allCases {
      let inBucket = sorted.filter {
        ConversationBucket.of(date($0), now: now, calendar: calendar) == bucket
      }
      if !inBucket.isEmpty { out.append((bucket, inBucket)) }
    }
    return out
  }

  /// The time of day for today's conversations, the weekday for the past week, otherwise the date.
  public static func timeText(_ date: Date, now: Date = .now, calendar: Calendar = .current)
    -> String
  {
    switch ConversationBucket.of(date, now: now, calendar: calendar) {
    case .today: return date.formatted(date: .omitted, time: .shortened)
    case .yesterday, .previous7Days: return date.formatted(.dateTime.weekday(.abbreviated))
    case .older: return date.formatted(.dateTime.month(.abbreviated).day())
    }
  }

  /// Conversations are about getting things done, so they settle by themselves: a chat archives itself after a week
  /// without a new message, or an hour after everything it added is done (reminders completed or deleted, events over,
  /// alarms rung or off). `settled` has one entry per item the chat added. Archived chats stay under "Archived".
  public static let autoArchiveIdleDays = 7

  public static func shouldAutoArchive(updatedAt: Date, settled: [Bool], now: Date = .now) -> Bool {
    let idle = now.timeIntervalSince(updatedAt)
    if idle >= Double(autoArchiveIdleDays) * 86_400 { return true }
    return !settled.isEmpty && settled.allSatisfy { $0 } && idle >= 3600
  }

  /// A conversation is titled by its first user message: whitespace collapsed, capped so one long paste stays a title.
  public static func title(from text: String, limit: Int = 80) -> String {
    let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard flat.count > limit else { return flat.isEmpty ? "New chat" : flat }
    return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

/// Value context rebuilt from this chat's stored messages on every send. No global/model session state.
public struct ConversationContext: Sendable {
  public struct Turn: Sendable {
    public let isUser: Bool
    public let text: String
    public var timestamp: Date? = nil

    public init(isUser: Bool, text: String, timestamp: Date? = nil) {
      self.isUser = isUser
      self.text = text
      self.timestamp = timestamp
    }
  }
  public let turns: [Turn]
  /// Deterministic reference recovery reads only supplied user messages from this thread.
  public let userTurns: [Turn]

  public init(_ lines: [(isUser: Bool, text: String)]) {
    self.init(turns: lines.map { Turn(isUser: $0.isUser, text: $0.text) })
  }

  public init(turns lines: [Turn]) {
    userTurns = lines.filter(\.isUser)
    var budget = 1600
    var kept: [Turn] = []
    for line in lines.suffix(8).reversed() {
      let text = String(line.text.prefix(min(400, budget)))
      guard !text.isEmpty else { continue }
      kept.append(Turn(isUser: line.isUser, text: text, timestamp: line.timestamp))
      budget -= text.count
      if budget == 0 { break }
    }
    turns = kept.reversed()
  }
}

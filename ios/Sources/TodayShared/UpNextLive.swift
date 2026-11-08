import Foundation

#if os(iOS)
  import ActivityKit
#endif

// The Lock Screen "Up Next" Live Activity: which rows it shows and what to do with the one activity.
// The selection and the decisions are plain Swift so `./dev test unit` covers them; the ActivityKit calls are in
// `Sources/One/UpNextActivity.swift` and the view in `TodayWidgets/UpNextLiveActivity.swift`.

/// One line on the card. Only what is drawn: a row id would change the content on every relaunch.
public struct UpNextRow: Codable, Hashable, Sendable {
  public var start: Date
  public var title: String

  public init(start: Date, title: String) {
    self.start = start
    self.title = title
  }
}

public enum UpNextLive {
  public static let window: TimeInterval = 3 * 3600
  public static let maxRows = 3
  /// ActivityKit caps the state at 4 KB and the card truncates long before this.
  static let maxTitleLength = 120

  /// Items with a clock time where `now < start <= now + 3 hours`, soonest first, at most three.
  /// Rolling, not by calendar day, so 23:00 includes 00:30 tomorrow. Ties keep the order they came in.
  /// `settledIDs`: items the user settled today; they take no slot, so the next item moves up.
  public static func rows(
    from items: [WidgetItem], now: Date, settledIDs: Set<String>
  ) -> [UpNextRow] {
    let end = now.addingTimeInterval(window)
    let timed = items.filter {
      !settledIDs.contains($0.id) && !$0.isAllDay && $0.startedEarlier != true
        && $0.start > now && $0.start <= end
    }
    let sorted = timed.enumerated().sorted {
      $0.element.start == $1.element.start
        ? $0.offset < $1.offset : $0.element.start < $1.element.start
    }
    return sorted.prefix(maxRows).map {
      UpNextRow(start: $0.element.start, title: String($0.element.title.prefix(maxTitleLength)))
    }
  }

  /// A reminder's clock time on its deadline, or nil when it is done or has no time of day (Today stores those at 00:00).
  public static func timedDue(_ due: Date?, isDone: Bool, calendar: Calendar = .current) -> Date? {
    guard !isDone, let due,
      calendar.dateComponents([.hour, .minute], from: due) != DateComponents(hour: 0, minute: 0)
    else { return nil }
    return due
  }

  /// UI tests and their launch arguments must never put a real card on the Lock Screen.
  public static func allowsRealActivity(arguments: [String]) -> Bool {
    !arguments.contains("-uiTesting")
  }
}

/// What to do with the single activity, given the rows it should show now.
public enum UpNextLifecycle {
  /// The system ends an activity after 8 active hours and an update does not extend that.
  public static let systemCap: TimeInterval = 8 * 3600
  /// Early enough that someone who opens the app hourly always reaches a foreground before the cap.
  public static let restartAge: TimeInterval = 7 * 3600

  /// The activity as it is now. An ended one still sits on the Lock Screen until it is dismissed.
  public struct Live: Equatable, Sendable {
    public var rows: [UpNextRow]
    public var requestedAt: Date
    public var isEnded: Bool

    public init(rows: [UpNextRow], requestedAt: Date, isEnded: Bool = false) {
      self.rows = rows
      self.requestedAt = requestedAt
      self.isEnded = isEnded
    }
  }

  public enum Action: Equatable, Sendable {
    case none, start, update, end, restart
  }

  /// `allowed`: the setting is on and the user has not dismissed the card today.
  /// `isForeground`: ActivityKit can only request an activity from the foreground; the background can update and end.
  public static func action(
    rows: [UpNextRow], live: Live?, allowed: Bool, isForeground: Bool, now: Date
  ) -> Action {
    guard allowed, !rows.isEmpty else { return live == nil ? .none : .end }
    guard let live else { return isForeground ? .start : .none }
    if live.isEnded || now.timeIntervalSince(live.requestedAt) >= restartAge {
      if isForeground { return .restart }
      if live.isEnded { return .none }
    }
    return live.rows == rows ? .none : .update
  }

  /// A dismissal hides the card for the rest of that calendar day.
  public static func isSuppressed(
    dismissedAt: Date?, now: Date, calendar: Calendar = .current
  ) -> Bool {
    guard let dismissedAt else { return false }
    return calendar.isDate(dismissedAt, inSameDayAs: now)
  }

  /// The card the app last started is gone and the app was not running to see why. Before the system cap only the user
  /// can have removed it; at or past the cap the system did.
  public static func vanishedByDismissal(requestedAt: Date?, now: Date) -> Bool {
    guard let requestedAt else { return false }
    return now.timeIntervalSince(requestedAt) < systemCap
  }
}

#if os(iOS)
  public struct UpNextAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
      public var rows: [UpNextRow]

      public init(rows: [UpNextRow]) {
        self.rows = rows
      }
    }

    /// Lives on the activity, so the age is known after a relaunch and the 8-hour restart needs no stored date.
    public var requestedAt: Date

    public init(requestedAt: Date) {
      self.requestedAt = requestedAt
    }
  }
#endif

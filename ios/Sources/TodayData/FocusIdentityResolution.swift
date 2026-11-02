import Foundation

/// Source identity only: which item in which account and calendar (and, in a repeating series, which occurrence).
/// Deletion checks it before writing, so a stale or changed source is never removed by mistake.
public struct FocusIdentity: Hashable, Codable, Sendable {
  public let provider: String
  public let account: String
  public let calendar: String
  public let item: String
  public let occurrence: Date?

  public init(
    provider: String, account: String, calendar: String, item: String, occurrence: Date? = nil
  ) {
    self.provider = provider
    self.account = account
    self.calendar = calendar
    self.item = item
    self.occurrence = occurrence
  }
}

/// Read-only source lookup. Unavailability is never evidence of deletion.
public enum FocusIdentityResolution: Equatable, Sendable {
  case available(FocusIdentity)
  case localOnly
  case unavailable
  case permissionDenied
  case notFound
}

import Foundation

/// Read-only source lookup. Unavailability is never evidence of deletion.
public enum FocusIdentityResolution: Equatable, Sendable {
  case available(FocusIdentity)
  case localOnly
  case unavailable
  case permissionDenied
  case notFound
}

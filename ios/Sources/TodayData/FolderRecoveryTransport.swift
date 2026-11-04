#if os(iOS)
  import Foundation

  /// Uses only a system-picker grant. No ubiquity entitlement or guessed iCloud path is needed.
  /// The bookmark is device local and must be obtained again after uninstalling the app.
  public final class FolderRecoveryTransport {
    private let bookmark: Data
    public init(bookmark: Data) { self.bookmark = bookmark }

    public static func bookmark(for selectedDirectory: URL) throws -> Data {
      guard selectedDirectory.startAccessingSecurityScopedResource() else {
        throw RecoveryArchive.Failure.unavailable
      }
      defer { selectedDirectory.stopAccessingSecurityScopedResource() }
      return try selectedDirectory.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A directory-level coordination encloses compare-and-swap as well as immutable writes.
    /// Account binding is supplied by the caller and checked before and after the operation.
    public func access<T>(account: () throws -> String, _ operation: (URL, String) throws -> T)
      throws -> T
    {
      var stale = false
      let directory = try URL(
        resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard !stale, directory.startAccessingSecurityScopedResource() else {
        throw RecoveryArchive.Failure.unavailable
      }
      defer { directory.stopAccessingSecurityScopedResource() }
      let identity = try account()
      var coordinationError: NSError?
      var result: Result<T, Error>?
      NSFileCoordinator().coordinate(
        writingItemAt: directory, options: .forMerging, error: &coordinationError
      ) { coordinatedURL in
        result = Result {
          guard try account() == identity else { throw RecoveryArchive.Failure.accountMismatch }
          let value = try operation(coordinatedURL, identity)
          guard try account() == identity else { throw RecoveryArchive.Failure.accountMismatch }
          return value
        }
      }
      if let coordinationError { throw coordinationError }
      guard let result else { throw RecoveryArchive.Failure.unavailable }
      return try result.get()
    }
  }
#endif

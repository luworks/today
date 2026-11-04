import Foundation

#if os(iOS)
  /// Requires an explicitly provisioned iCloud Documents container. Never falls back to a
  /// guessed filesystem path or treats unavailable account metadata as an absent backup.
  public final class UbiquityRecoveryTransport {
    public enum Availability { case unavailable, downloading, absent, available(Data) }
    private let containerIdentifier: String
    public init(containerIdentifier: String) { self.containerIdentifier = containerIdentifier }

    private func backupURL() throws -> URL {
      guard FileManager.default.ubiquityIdentityToken != nil,
        let root = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
      else { throw RecoveryArchive.Failure.unavailable }
      return root.appendingPathComponent("Documents/Today/Recovery.todaybackup")
    }

    /// Invoke off the main thread. A metadata query must finish discovery before the caller
    /// may classify an absent path as a new account with no existing backup.
    public func read(discoveryFinished: Bool) throws -> Availability {
      let url = try backupURL()
      guard FileManager.default.fileExists(atPath: url.path) else {
        return discoveryFinished ? .absent : .unavailable
      }
      let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
      guard values.ubiquitousItemDownloadingStatus == .current else {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        return .downloading
      }
      var coordinationError: NSError?
      var result: Result<Data, Error>?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
        coordinatedURL in
        result = Result { try Data(contentsOf: coordinatedURL) }
      }
      if let coordinationError { throw coordinationError }
      guard let result else { throw RecoveryArchive.Failure.unavailable }
      return .available(try result.get())
    }

    /// Successful return means staged in the iCloud container, not uploaded to Apple's servers.
    /// The caller must separately observe ubiquitousItemIsUploaded and upload errors.
    public func publish(_ data: Data, gate: RecoveryPublicationGate) throws {
      guard gate.mayPublish else { throw RecoveryArchive.Failure.unavailable }
      let url = try backupURL()
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var coordinationError: NSError?
      var writeError: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: url, options: .forReplacing, error: &coordinationError
      ) { coordinatedURL in
        do { try data.write(to: coordinatedURL, options: .atomic) } catch { writeError = error }
      }
      if let coordinationError { throw coordinationError }
      if let writeError { throw writeError }
    }
  }
#endif

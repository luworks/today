import Foundation

/// Immutable generations plus an atomic head. The head is authoritative: recovery never scans
/// backwards after a clear, retention change or a damaged current generation.
public enum RecoveryGenerations {
  public enum Failure: Error { case conflict, downloading, invalidHead }

  public static func read(in directory: URL, account: String) throws -> RecoveryArchive.Validated? {
    let head = directory.appendingPathComponent("head.json")
    guard FileManager.default.fileExists(atPath: head.path) else {
      // File providers may expose a placeholder before materializing its logical URL.
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      guard !names.contains(".head.json.icloud") else { throw Failure.downloading }
      guard
        !names.contains(where: {
          $0.hasSuffix(".todaybackup") || $0.hasSuffix(".todaybackup.icloud")
        })
      else {
        throw Failure.invalidHead
      }
      return nil
    }
    let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: head))
    let url = directory.appendingPathComponent(id.uuidString + ".todaybackup")
    #if os(iOS)
      let values = try url.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      ])
      if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw Failure.downloading
      }
    #endif
    let archive = try RecoveryArchive.validate(Data(contentsOf: url), account: account)
    guard archive.manifest.generation == id else { throw Failure.invalidHead }
    return archive
  }

  /// Caller coordinates the directory across the read/compare/write transaction. A competing
  /// device's head is retained and reported; no automatic merge or last-writer-wins replacement.
  @discardableResult
  public static func publish(
    _ data: Data, in directory: URL, account: String, expected: UUID?,
    localHasUserData: Bool, explicitlyCleared: Bool = false
  ) throws -> UUID {
    let archive = try RecoveryArchive.validate(data, account: account)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let current = try read(in: directory, account: account)
    var gate = RecoveryPublicationGate()
    gate.remote = current.map { .valid($0.manifest.generation) } ?? .absent
    gate.acknowledged = expected
    gate.localHasUserData = localHasUserData
    gate.explicitlyCleared = explicitlyCleared
    guard gate.mayPublish, current?.manifest.generation == expected else { throw Failure.conflict }
    let id = archive.manifest.generation
    let destination = directory.appendingPathComponent(id.uuidString + ".todaybackup")
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.conflict }
    try data.write(to: destination, options: .atomic)
    // Read back before advancing head. A failed head write leaves the previous good head intact.
    _ = try RecoveryArchive.validate(Data(contentsOf: destination), account: account)
    try JSONEncoder().encode(id).write(
      to: directory.appendingPathComponent("head.json"), options: .atomic)
    return id
  }
}

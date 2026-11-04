import Foundation
import CryptoKit
import SQLite3

/// Transport-independent recovery format. Callers must export an explicit allowlist of user data;
/// credentials, Health values and runtime system alarm identifiers must never enter a payload.
public enum RecoveryArchive {
  public enum Failure: Error { case unsupportedVersion, corrupt, accountMismatch, localDataExists, unavailable, sqlite }

  public struct Manifest: Codable, Equatable {
    public let version: Int
    public let account: String
    public let generation: UUID
    public let created: Date
    public let hashes: [String: String]
  }

  private struct Envelope: Codable {
    var manifest: Manifest
    var files: [String: Data]
  }

  public struct Validated {
    public let manifest: Manifest
    public let files: [String: Data]
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Single immutable object: readers never observe a manifest from another generation.
  public static func encode(files: [String: Data], account: String, now: Date = .now) throws -> Data {
    guard !account.isEmpty, !files.isEmpty,
      files.keys.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") })
    else { throw Failure.corrupt }
    let manifest = Manifest(version: 1, account: account, generation: UUID(), created: now,
      hashes: files.mapValues(digest))
    return try JSONEncoder().encode(Envelope(manifest: manifest, files: files))
  }

  public static func validate(_ data: Data, account: String) throws -> Validated {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.manifest.version == 1 else { throw Failure.unsupportedVersion }
    guard envelope.manifest.account == account else { throw Failure.accountMismatch }
    guard !envelope.files.isEmpty,
      envelope.manifest.hashes == envelope.files.mapValues(digest),
      envelope.files.keys.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") })
    else { throw Failure.corrupt }
    return Validated(manifest: envelope.manifest, files: envelope.files)
  }

  /// Restoration is staged only into a brand-new directory. The application must validate its
  /// own payload schemas before activating this directory and before starting source sync.
  public static func stage(_ archive: Validated, at destination: URL) throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: destination.path) else { throw Failure.localDataExists }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    for (name, data) in archive.files {
      try data.write(to: staging.appendingPathComponent(name), options: .atomic)
    }
    try fm.moveItem(at: staging, to: destination)
  }

  /// SQLite's backup API includes committed WAL pages. A busy writer produces a retryable
  /// failure after the configured SQLite timeout; no partial destination is published.
  public static func sqliteSnapshot(at source: URL) throws -> Data {
    var input: OpaquePointer?
    guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let input else { if let input { sqlite3_close(input) }; throw Failure.sqlite }
    defer { sqlite3_close(input) }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }
    var output: OpaquePointer?
    guard sqlite3_open(target.path, &output) == SQLITE_OK, let output else {
      if let output { sqlite3_close(output) }; throw Failure.sqlite
    }
    defer { sqlite3_close(output) }
    guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure.sqlite }
    let result = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.sqlite }
    return try Data(contentsOf: target)
  }
}

/// Fail-closed publication gate. A missing placeholder/download is not an empty remote.
/// Persist the selected account and acknowledged generation locally outside this value.
public struct RecoveryPublicationGate: Sendable {
  public enum Remote: Sendable { case unresolved, absent, valid(UUID), invalid }
  public var remote: Remote = .unresolved
  public var acknowledged: UUID?
  public var localHasUserData = false
  public var explicitlyCleared = false
  public init() {}

  public var mayPublish: Bool {
    guard localHasUserData || explicitlyCleared else { return false }
    switch remote {
    case .absent: return true
    case .valid(let generation): return acknowledged == generation
    case .unresolved, .invalid: return false
    }
  }
}

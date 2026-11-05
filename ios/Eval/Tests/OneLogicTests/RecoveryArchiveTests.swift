import SQLite3
import XCTest

@testable import TodayData

final class RecoveryArchiveTests: XCTestCase {
  func testSaveCleanRebuildRestoreAndRefuseOverwrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try RecoveryArchive.encode(
      files: ["planner.json": Data("saved reminder".utf8)], account: "a")
    let backup = try RecoveryArchive.validate(data, account: "a")
    let restored = root.appendingPathComponent("restored")
    try RecoveryArchive.stage(backup, at: restored)
    XCTAssertEqual(
      try Data(contentsOf: restored.appendingPathComponent("planner.json")),
      Data("saved reminder".utf8))
    XCTAssertThrowsError(try RecoveryArchive.stage(backup, at: restored))
  }

  func testCorruptionOldSchemaAndAccountIsolation() throws {
    let data = try RecoveryArchive.encode(files: ["chat.json": Data("chat".utf8)], account: "a")
    XCTAssertThrowsError(try RecoveryArchive.validate(data, account: "b"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var manifest = try XCTUnwrap(object["manifest"] as? [String: Any])
    manifest["version"] = 0
    object["manifest"] = manifest
    XCTAssertThrowsError(
      try RecoveryArchive.validate(JSONSerialization.data(withJSONObject: object), account: "a"))
    manifest["version"] = 1
    object["manifest"] = manifest
    object["files"] = ["chat.json": Data("changed".utf8).base64EncodedString()]
    XCTAssertThrowsError(
      try RecoveryArchive.validate(JSONSerialization.data(withJSONObject: object), account: "a"))
    XCTAssertNoThrow(try RecoveryArchive.validate(data, account: "a"))
  }

  func testEmptyAndUnresolvedRemoteNeverOverwriteLastGoodBackup() {
    var gate = RecoveryPublicationGate()
    gate.remote = .absent
    XCTAssertFalse(gate.mayPublish)
    gate.localHasUserData = true
    gate.remote = .unresolved
    XCTAssertFalse(gate.mayPublish)
    gate.remote = .invalid
    XCTAssertFalse(gate.mayPublish)
    let generation = UUID()
    gate.remote = .valid(generation)
    XCTAssertFalse(gate.mayPublish)
    gate.acknowledged = generation
    XCTAssertTrue(gate.mayPublish)
    gate.localHasUserData = false
    gate.explicitlyCleared = true
    XCTAssertTrue(gate.mayPublish)
  }

  func testGenerationsConflictCorruptionAndClearNeverFallBack() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let placeholder = directory.appendingPathComponent(".head.json.icloud")
    try Data().write(to: placeholder)
    XCTAssertThrowsError(try RecoveryGenerations.read(in: directory, account: "a"))
    try FileManager.default.removeItem(at: placeholder)
    let first = try RecoveryArchive.encode(
      files: ["planner.json": Data("old data".utf8)], account: "a")
    let id = try RecoveryGenerations.publish(
      first, in: directory, account: "a", expected: nil, localHasUserData: true)
    let next = try RecoveryArchive.encode(
      files: ["planner.json": Data("new data".utf8)], account: "a")
    XCTAssertThrowsError(
      try RecoveryGenerations.publish(
        next, in: directory, account: "a", expected: nil, localHasUserData: true))
    XCTAssertEqual(
      try RecoveryGenerations.read(in: directory, account: "a")?.manifest.generation, id)
    XCTAssertThrowsError(
      try RecoveryGenerations.publish(
        next, in: directory, account: "a", expected: id, localHasUserData: false))
    let cleared = try RecoveryArchive.encode(files: ["planner.json": Data("[]".utf8)], account: "a")
    let clearID = try RecoveryGenerations.publish(
      cleared, in: directory, account: "a", expected: id, localHasUserData: false,
      explicitlyCleared: true)
    XCTAssertEqual(
      try RecoveryGenerations.read(in: directory, account: "a")?.files["planner.json"],
      Data("[]".utf8))
    XCTAssertThrowsError(try RecoveryGenerations.read(in: directory, account: "b"))
    try Data("damaged".utf8).write(
      to: directory.appendingPathComponent(clearID.uuidString + ".todaybackup"))
    XCTAssertThrowsError(try RecoveryGenerations.read(in: directory, account: "a"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(id.uuidString + ".todaybackup").path))
  }

  func testSnapshotIncludesCommittedWAL() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("live.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "PRAGMA journal_mode=WAL; CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('saved');",
        nil, nil, nil), SQLITE_OK)
    let snapshot = try RecoveryArchive.sqliteSnapshot(at: source)
    let restored = root.appendingPathComponent("restored.sqlite")
    try snapshot.write(to: restored)
    var read: OpaquePointer?
    XCTAssertEqual(sqlite3_open(restored.path, &read), SQLITE_OK)
    defer { sqlite3_close(read) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(read, "SELECT value FROM sample", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "saved")
  }
}

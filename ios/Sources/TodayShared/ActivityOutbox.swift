import Foundation

/// How extensions (Share, widgets) and anything that can run while the app is suspended leave Activity events for the app.
/// They never open `activity.sqlite` (iOS kills a process that holds a SQLite lock when it is suspended): each write is one
/// small JSONL file with a unique name in the App Group folder `activity-outbox/`, written atomically, no locking. The app
/// imports the folder when it becomes active (`ActivityOutboxImport`), in one transaction, then deletes the files.
///
/// The line format is the Activity export format (`ActivityJSONL` in the app): snake_case keys, `props` a nested object. This file
/// only knows the few keys an extension can fill; the app fills `device`, `session` and anything else. Foundation only, shared by
/// the app and the extensions, covered by `swift test`.
public enum ActivityOutbox {
  public static let folderName = "activity-outbox"
  /// More files than this and new ones are dropped (nothing drains an outbox while the app is not used).
  public static let maxFiles = 500

  public static var folderURL: URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
      .appendingPathComponent(folderName, isDirectory: true)
  }

  /// Writes one event. `props` holds no free text; a title goes in `title`. Returns false when the App Group is unavailable,
  /// the outbox is full or the write fails.
  @discardableResult
  public static func append(
    kind: String, tier: Int = 4, actor: String, channel: String? = nil, props: [String: Any] = [:],
    subjectKind: String? = nil, subjectRef: String? = nil, title: String? = nil,
    at date: Date = .now, in folder: URL? = folderURL
  ) -> Bool {
    guard let folder else { return false }
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      #if os(iOS)
        try? fm.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: folder.path)
      #endif
      if (try? fm.contentsOfDirectory(atPath: folder.path).count) ?? 0 >= maxFiles { return false }
      let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
      let cal = Calendar.current
      let c = cal.dateComponents([.year, .month, .day], from: date)
      var line: [String: Any] = [
        "uid": UUID().uuidString, "ts": ms, "tz": cal.timeZone.secondsFromGMT(for: date) / 60,
        "day": (c.year ?? 1970) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1),
        "tier": tier, "kind": kind, "actor": actor, "v": 1, "props": props,
      ]
      if let channel { line["channel"] = channel }
      if let subjectKind { line["subject_kind"] = subjectKind }
      if let subjectRef { line["subject_ref"] = subjectRef }
      if let title { line["title"] = title }
      var data = try JSONSerialization.data(
        withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
      data.append(0x0A)
      let name = "\(ms)-\(UUID().uuidString).jsonl"
      try data.write(to: folder.appendingPathComponent(name), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// The files waiting, oldest first (the name starts with the time).
  public static func pendingFiles(in folder: URL? = folderURL) -> [URL] {
    guard let folder,
      let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".jsonl") }.sorted().map {
      folder.appendingPathComponent($0)
    }
  }

  public static func remove(_ files: [URL]) {
    for f in files { try? FileManager.default.removeItem(at: f) }
  }
}

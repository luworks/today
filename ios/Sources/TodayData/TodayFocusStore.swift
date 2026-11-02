import Foundation

/// Source identity only. Content changes never change a focus decision; identity changes never inherit it.
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
  /// Source-item equality deliberately excludes the occurrence within a repeating series.
  public func sameItem(as other: FocusIdentity) -> Bool {
    provider == other.provider && account == other.account
      && calendar == other.calendar && item == other.item
  }

}

public enum TodayFocusState: Equatable, Codable, Sendable {
  case active
  case settled
  case snoozed(until: Date)
}

public struct FocusRecord: Equatable, Codable, Sendable {
  public let identity: FocusIdentity
  public let state: TodayFocusState
  public let changedAt: Date
  /// The selected agenda day; absent in older records, which apply to the day they were changed.
  public let settledDay: Date?
  /// Time zone in which the selected civil day was recorded.
  public let settledTimeZone: String?
  /// Opaque local record anchor; it never substitutes for a resolved source identity.
  public let localReference: String?

  public init(
    identity: FocusIdentity, state: TodayFocusState, changedAt: Date, localReference: String? = nil,
    settledDay: Date? = nil, settledTimeZone: String? = nil
  ) {
    self.identity = identity
    self.state = state
    self.changedAt = changedAt
    self.settledDay = settledDay
    self.settledTimeZone = settledTimeZone
    self.localReference = localReference
  }
  /// Reconstruct the selected civil day in the current time zone after travel.
  public func agendaDay(calendar: Calendar) -> Date {
    guard let settledDay, let settledTimeZone,
      let zone = TimeZone(identifier: settledTimeZone)
    else { return self.settledDay ?? changedAt }
    var original = calendar
    original.timeZone = zone
    let components = original.dateComponents([.era, .year, .month, .day], from: settledDay)
    return calendar.date(from: components) ?? settledDay
  }
}

public enum TodayFocusStoreError: Error, Equatable {
  case unsupportedVersion(Int)
  case corruptPayload
  case invalidIdentity
  case invalidTime
  case concurrentChange
}

/// A small Today-only overlay, independent of Activity retention and recovery.
public final class TodayFocusStore {
  public enum Location: Equatable {
    case memory
    case file(URL)
  }

  // All overlay instances in the app process share the commit lock.
  private static let diskLock = NSLock()
  private struct Payload: Codable {
    let version: Int
    let records: [FocusRecord]
  }

  public let location: Location
  private let lock = NSLock()
  private var persisted: Data?
  private var storedRecords: [FocusRecord]

  public init(location: Location) throws {
    self.location = location
    Self.diskLock.lock()
    defer { Self.diskLock.unlock() }
    let raw = try Self.read(location)
    storedRecords = try Self.decode(raw)
    persisted = raw
  }

  private static func read(_ location: Location) throws -> Data? {
    guard case .file(let url) = location else { return nil }
    do { return try Data(contentsOf: url) } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
    { return nil }
  }

  public var records: [FocusRecord] {
    lock.lock()
    defer { lock.unlock() }
    return storedRecords
  }

  /// Expiration is a read-time decision: no timer, midnight reset, or source mutation is required.
  public func state(
    for identity: FocusIdentity, now: Date, on day: Date? = nil, calendar: Calendar = .current
  )
    -> TodayFocusState?
  {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
    guard let record = record(for: identity, on: day ?? now, calendar: calendar) else { return nil }
    if case .active = record.state { return nil }
    if case .settled = record.state {
      let start = calendar.startOfDay(for: record.agendaDay(calendar: calendar))
      guard let end = calendar.date(byAdding: .day, value: 1, to: start), now < end else {
        return nil
      }
    }
    if case .snoozed(let until) = record.state, until <= now { return nil }
    return record.state
  }

  public func record(for identity: FocusIdentity, on day: Date, calendar: Calendar = .current)
    -> FocusRecord?
  {
    lock.lock()
    defer { lock.unlock() }
    return storedRecords.first {
      $0.identity == identity && calendar.isDate($0.agendaDay(calendar: calendar), inSameDayAs: day)
    }
      ?? storedRecords.first {
        guard $0.identity == identity else { return false }
        if case .snoozed = $0.state { return true }
        return false
      }
  }

  public func set(
    state: TodayFocusState?, for identity: FocusIdentity, now: Date, localReference: String? = nil,
    on day: Date? = nil, calendar: Calendar = .current
  ) throws {
    try Self.validate(identity)
    guard now.timeIntervalSinceReferenceDate.isFinite else {
      throw TodayFocusStoreError.invalidTime
    }
    if let state { try Self.validate(state, changedAt: now) }
    let selectedDay = calendar.startOfDay(for: day ?? now)
    lock.lock()
    defer { lock.unlock() }
    let reference =
      localReference ?? storedRecords.first(where: { $0.identity == identity })?.localReference
    var next = storedRecords.filter {
      $0.identity != identity
        || !calendar.isDate($0.agendaDay(calendar: calendar), inSameDayAs: selectedDay)
    }
    if let state {
      next.append(
        FocusRecord(
          identity: identity, state: state, changedAt: now, localReference: reference,
          settledDay: day == nil ? nil : selectedDay,
          settledTimeZone: day == nil ? nil : calendar.timeZone.identifier))
    }
    try commit(next)
  }

  public func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    try commit([])
  }

  /// A newly resolved identity invalidates older fallback anchors without discarding their source decisions.
  public func detachReference(_ reference: String, except identity: FocusIdentity) throws {
    lock.lock()
    defer { lock.unlock() }
    guard
      storedRecords.contains(where: {
        $0.localReference == reference && !$0.identity.sameItem(as: identity)
      })
    else { return }
    let next = storedRecords.map { record in
      guard record.localReference == reference, !record.identity.sameItem(as: identity) else {
        return record
      }
      return FocusRecord(
        identity: record.identity, state: record.state, changedAt: record.changedAt,
        settledDay: record.settledDay, settledTimeZone: record.settledTimeZone)
    }
    try commit(next)
  }

  private func commit(_ next: [FocusRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(Payload(version: 2, records: next))
    // Validate the exact bytes before any replacement, including the empty clear payload.
    guard try Self.decode(encoded) == next else { throw TodayFocusStoreError.corruptPayload }
    Self.diskLock.lock()
    defer { Self.diskLock.unlock() }
    if case .file(let url) = location {
      guard try Self.read(location) == persisted else {
        throw TodayFocusStoreError.concurrentChange
      }
      let fm = FileManager.default
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let temporary = url.deletingLastPathComponent().appendingPathComponent(
        ".focus-\(UUID().uuidString).tmp")
      defer { try? fm.removeItem(at: temporary) }
      try encoded.write(to: temporary, options: .atomic)
      guard try Data(contentsOf: temporary) == encoded else {
        throw TodayFocusStoreError.corruptPayload
      }
      if persisted == nil {
        try fm.moveItem(at: temporary, to: url)
      } else {
        _ = try fm.replaceItemAt(url, withItemAt: temporary)
      }
    }
    persisted = encoded
    storedRecords = next
  }

  private static func decode(_ raw: Data?) throws -> [FocusRecord] {
    guard let raw else { return [] }
    do {
      let data = raw
      // Read the version first so even an otherwise unfamiliar newer payload remains untouched.
      struct Version: Decodable { let version: Int }
      let version = try JSONDecoder().decode(Version.self, from: data).version
      guard version == 1 || version == 2 else {
        throw TodayFocusStoreError.unsupportedVersion(version)
      }
      let payload = try JSONDecoder().decode(Payload.self, from: data)
      struct RecordKey: Hashable {
        let identity: FocusIdentity
        let day: Date
        let timeZone: String?
      }
      var identities = Set<RecordKey>()
      var legacyIdentities = Set<FocusIdentity>()
      for record in payload.records {
        try validate(record.identity)
        try validate(record.state, changedAt: record.changedAt)
        if let day = record.settledDay, !day.timeIntervalSinceReferenceDate.isFinite {
          throw TodayFocusStoreError.invalidTime
        }
        if let zone = record.settledTimeZone, TimeZone(identifier: zone) == nil {
          throw TodayFocusStoreError.corruptPayload
        }
        let key = RecordKey(
          identity: record.identity, day: record.settledDay ?? record.changedAt,
          timeZone: record.settledTimeZone)
        guard identities.insert(key).inserted,
          version != 1 || legacyIdentities.insert(record.identity).inserted
        else {
          throw TodayFocusStoreError.corruptPayload
        }
      }
      return payload.records
    } catch let error as TodayFocusStoreError {
      throw error
    } catch {
      throw TodayFocusStoreError.corruptPayload
    }
  }

  private static func validate(_ identity: FocusIdentity) throws {
    guard
      [identity.provider, identity.account, identity.calendar, identity.item].allSatisfy({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw TodayFocusStoreError.invalidIdentity }
    if let occurrence = identity.occurrence, !occurrence.timeIntervalSinceReferenceDate.isFinite {
      throw TodayFocusStoreError.invalidTime
    }
  }

  private static func validate(_ state: TodayFocusState, changedAt: Date) throws {
    guard changedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw TodayFocusStoreError.invalidTime
    }
    if case .snoozed(let until) = state {
      guard until.timeIntervalSinceReferenceDate.isFinite, until > changedAt else {
        throw TodayFocusStoreError.invalidTime
      }
    }
  }
}

#if os(iOS)
  import Foundation
  import CoreFoundation
  import SwiftData
  import UIKit
  import Observation
  import TodayData

  /// Folder grants and backup metadata are local; archive contents are explicitly selected.
  @MainActor @Observable
  package final class BackupController {
    package static let shared = BackupController()
    package private(set) var status = "Choose a folder to enable automatic backups."
    package private(set) var folder = ""
    package private(set) var lastSaved: Date?
    package private(set) var hasRemote = false
    private var remote: RecoveryArchive.Validated?
    private var transport: FolderRecoveryTransport?
    private var account = ""
    private var expected: UUID?
    private var container: ModelContainer?
    private var activity: ActivityCenter?
    private var activityURL: URL?
    private var testFolder: URL?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var suspended = false
    private let defaults: UserDefaults
    private let restoreRoot: URL
    private let preferencesDomain: String
    private let identityProvider: () throws -> String
    package init(
      defaults: UserDefaults = .standard, restoreRoot: URL = BackupController.root,
      identity: (() throws -> String)? = nil, testFolder: URL? = nil,
      preferencesDomain: String = Bundle.main.bundleIdentifier ?? "com.luworks.today"
    ) {
      self.preferencesDomain = preferencesDomain
      self.testFolder = testFolder
      self.defaults = defaults
      folder = defaults.string(forKey: "backup.folder") ?? ""
      lastSaved = defaults.object(forKey: "backup.saved") as? Date
      self.restoreRoot = restoreRoot
      self.identityProvider = identity ?? Self.currentIdentity
      if let bookmark = defaults.data(forKey: "backup.bookmark") {
        transport =
          testFolder.map { FolderRecoveryTransport(localDirectory: $0) }
          ?? FolderRecoveryTransport(bookmark: bookmark)
        account = defaults.string(forKey: "backup.account") ?? ""
        expected = defaults.string(forKey: "backup.head").flatMap(UUID.init(uuidString:))
      }
    }
    package static func cancelRestore(defaults: UserDefaults) {
      for key in [
        "backup.pending", "backup.pendingGeneration", "backup.pendingAccount",
        "backup.pendingBookmark",
      ] {
        defaults.removeObject(forKey: key)
      }
    }
    package func cancelRestore() {
      pending?.cancel()
      Self.cancelRestore(defaults: defaults)
    }
    package static func explicitPreferences(_ defaults: UserDefaults, domain: String) -> [String:
      Any]
    {
      let saved = defaults.persistentDomain(forName: domain) ?? [:]
      return saved.filter { preferenceKeys.contains($0.key) }
    }
    package static let preferenceKeys = [
      "today.appearance", "today.setting.showAlarmsInToday", "today.setting.jumpToNow",
      "today.setting.autoArchiveChats", "today.setting.travelTime", "today.setting.healthSummary",
      "today.setting.compressEmptyHours", "today.setting.dimPastDays", "today.setting.firstWeekday",
      "today.setting.weekNumbers", "today.setting.calendarStart", "today.setting.showSettle",
      "today.setting.showFreeTime", "today.setting.newReminderList",
      "today.setting.newEventCalendar",
      "today.setting.newEventAlert", "today.setting.newAlarmSnooze", "today.setting.newAlarmSound",
      "today.setting.afternoonStart", "today.setting.eveningStart",
      "today.setting.freeRowMinutes", "today.setting.newEventMinutes",
      "today.setting.quickPresets",
      "today.setting.reminderInterruption",
      "today.setting.aiChanges",
      "today.worldClock.cities", "reminders.smartOrder", "reminders.smartHidden",
      "activity.setting.tier.1", "activity.setting.tier.2", "activity.setting.tier.3",
      "activity.setting.tier.4",
      "activity.setting.paused", "activity.setting.retention", "activity.setting.keepChatText",
    ]
    package static var root: URL {
      URL.applicationSupportDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }
    package static var active: URL? {
      UserDefaults.standard.string(forKey: "backup.active").map { root.appendingPathComponent($0) }
    }
    package static var schema: Schema {
      Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, ChatThread.self,
        ShareImportReceipt.self,
      ])
    }
    private func identity() throws -> String { try identityProvider() }
    private static func currentIdentity() throws -> String {
      let token = FileManager.default.ubiquityIdentityToken
      if let token {
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
          .base64EncodedString()
      }
      return "selected-folder-local"
    }
    package func reportRestoreFailure(_ error: Error) {
      suspended = true
      status = "Restore could not be activated. Original data retained. \(error)"
    }

    package func attach(_ session: PlannerSession) {
      bind(
        container: session.container, activity: session.activity,
        activityURL: Self.active?.appendingPathComponent("activity.sqlite")
          ?? ActivityStore.defaultURL())
      session.activity.beforeClear = { [weak self] in self?.cancelRestore() }
      if let bookmark = defaults.data(forKey: "backup.bookmark") {
        transport =
          testFolder.map { FolderRecoveryTransport(localDirectory: $0) }
          ?? FolderRecoveryTransport(bookmark: bookmark)
        account = defaults.string(forKey: "backup.account") ?? ""
        expected = defaults.string(forKey: "backup.head").flatMap(UUID.init(uuidString:))
        do { try discover() } catch {
          status = "Backup unavailable. Re-select the folder or retry. \(error)"
        }
      }
      if defaults.string(forKey: "backup.pending") != nil { suspended = true }
      for name in [
        ModelContext.didSave, Notification.Name("ActivityCenter.didChange"),
        UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name,
            object: name == ModelContext.didSave ? session.container.mainContext : nil, queue: .main
          ) {
            [weak self] _ in
            Task { @MainActor in self?.schedule() }
          })
      }
    }
    package func bind(container: ModelContainer, activity: ActivityCenter, activityURL: URL) {
      self.container = container
      self.activity = activity
      self.activityURL = activityURL
      activity.beforeClear = { [weak self] in self?.cancelRestore() }
    }
    package func select(_ url: URL) {
      do {
        let bookmark =
          try testFolder.map { Data($0.path.utf8) } ?? FolderRecoveryTransport.bookmark(for: url)
        let selected =
          testFolder.map { FolderRecoveryTransport(localDirectory: $0) }
          ?? FolderRecoveryTransport(bookmark: bookmark)
        let binding = try identity()
        let found = try selected.access(account: { try self.identity() }) { directory, _ in
          try RecoveryGenerations.read(in: directory, account: binding)
        }
        transport = selected
        account = binding
        remote = found
        hasRemote = found != nil
        expected = nil
        suspended = found != nil
        folder = url.lastPathComponent
        defaults.set(bookmark, forKey: "backup.bookmark")
        defaults.set(binding, forKey: "backup.account")
        defaults.set(folder, forKey: "backup.folder")
        defaults.removeObject(forKey: "backup.head")
        status =
          found == nil
          ? "Folder selected. Automatic backup is enabled."
          : "Backup found. Keep both or restore on next launch. Automatic backup is paused."
        if found == nil { schedule() }
      } catch { status = "Folder unavailable. Nothing was replaced. \(error)" }
    }
    private func discover() throws {
      guard let transport else { return }
      guard try identity() == account else { throw RecoveryArchive.Failure.accountMismatch }
      remote = try transport.access(account: { try self.identity() }) { directory, _ in
        try RecoveryGenerations.read(in: directory, account: self.account)
      }
      hasRemote = remote != nil
      suspended =
        defaults.string(forKey: "backup.pending") != nil || remote?.manifest.generation != expected
      status =
        suspended
        ? "Backup found. Automatic backup paused; choose Restore or keep both."
        : "Automatic backup enabled."
    }
    package func schedule() {
      guard transport != nil, !suspended else { return }
      pending?.cancel()
      pending = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        self?.save()
      }
    }
    package func retry() {
      do {
        expected = defaults.string(forKey: "backup.head").flatMap(UUID.init(uuidString:))
        try discover()
        if !suspended { save() }
      } catch { status = "Backup unavailable; local data is safe. \(error)" }
    }
    package func save() {
      guard defaults.string(forKey: "backup.pending") == nil, !busy, !suspended, let container,
        let activity, let activityURL, let transport
      else {
        return
      }
      busy = true
      defer { busy = false }
      do {
        guard try identity() == account else { throw RecoveryArchive.Failure.accountMismatch }
        if container.mainContext.hasChanges { try container.mainContext.save() }
        activity.recorder.flush()
        let count =
          try container.mainContext.fetchCount(FetchDescriptor<OneTask>())
          + container.mainContext.fetchCount(FetchDescriptor<ChatThread>())
          + container.mainContext.fetchCount(FetchDescriptor<OneEvent>())
          + container.mainContext.fetchCount(FetchDescriptor<OneAlarm>())
          + container.mainContext.fetchCount(FetchDescriptor<OneList>())
          + (try activity.store?.count() ?? 0)
          + Self.explicitPreferences(defaults, domain: preferencesDomain).count
        guard count > 0 || expected != nil else {
          status = "Folder selected. Waiting for data before the first backup."
          return
        }
        let files = try Self.payload(
          container: container,
          activityURL: activityURL, defaults: defaults, preferencesDomain: preferencesDomain)
        let data = try RecoveryArchive.encode(files: files, account: account)
        expected = try transport.access(account: { try self.identity() }) { directory, _ in
          try RecoveryGenerations.publish(
            data, in: directory, account: self.account, expected: self.expected,
            localHasUserData: true)
        }
        remote = try RecoveryArchive.validate(data, account: account)
        hasRemote = true
        defaults.set(expected?.uuidString, forKey: "backup.head")
        lastSaved = .now
        defaults.set(lastSaved, forKey: "backup.saved")
        status = "Saved to selected folder. Files manages cloud synchronization."
      } catch {
        status = "Backup failed; previous backup retained. Retry or re-select folder. \(error)"
      }
    }
    package static func payload(
      container: ModelContainer, activityURL: URL, defaults: UserDefaults,
      preferencesDomain: String = Bundle.main.bundleIdentifier ?? "com.luworks.today"
    )
      throws -> [String: Data]
    {
      let store = container.configurations.first!.url
      // The current schema uses inline Data. Refuse unknown external storage rather than omit it.
      let support = store.deletingLastPathComponent().appendingPathComponent(
        ".\(store.lastPathComponent)_SUPPORT")
      guard !FileManager.default.fileExists(atPath: support.path) else {
        throw RecoveryArchive.Failure.unsupportedVersion
      }
      let scratch = Self.root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let snapshot = scratch.appendingPathComponent("default.store")
      try RecoveryArchive.sqliteSnapshot(at: store).write(to: snapshot)
      // Sanitize only the copy: restored alarms require explicit review, never an old runtime ID.
      do {
        let copy = try ModelContainer(
          for: Self.schema, configurations: ModelConfiguration(url: snapshot))
        for alarm in try copy.mainContext.fetch(FetchDescriptor<OneAlarm>()) {
          alarm.alarmKitID = nil
          alarm.isOn = false
        }
        for task in try copy.mainContext.fetch(FetchDescriptor<OneTask>()) {
          task.ringsAsAlarm = false
        }
        try copy.mainContext.save()
      }
      let preferences = Self.explicitPreferences(defaults, domain: preferencesDomain)
      let historyCopy = scratch.appendingPathComponent("activity.sqlite")
      try RecoveryArchive.sqliteSnapshot(at: activityURL).write(to: historyCopy)
      do {
        let history = try ActivityStore(location: .file(historyCopy))
        try history.setMeta("device", nil)
      }
      return [
        "default.store": try RecoveryArchive.sqliteSnapshot(at: snapshot),
        "activity.sqlite": try RecoveryArchive.sqliteSnapshot(at: historyCopy),
        "preferences.json": try JSONSerialization.data(withJSONObject: preferences),
        "payload.json": Data(
          "{\"payloadVersion\":1,\"appSchemaVersion\":1,\"components\":[\"swiftdata\",\"activity\",\"preferences\"]}"
            .utf8),
      ]
    }
    package func stageRestore() {
      guard let remote, let transport else { return }
      do {
        guard try identity() == account else { throw RecoveryArchive.Failure.accountMismatch }
        try transport.access(account: { try self.identity() }) { directory, _ in
          guard
            try RecoveryGenerations.read(in: directory, account: self.account)?.manifest.generation
              == remote.manifest.generation
          else { throw RecoveryGenerations.Failure.conflict }
        }
        guard
          Set(remote.files.keys)
            == Set(["default.store", "activity.sqlite", "preferences.json", "payload.json"])
        else { throw RecoveryArchive.Failure.unsupportedVersion }
        let name = UUID().uuidString
        try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
        try RecoveryArchive.stage(remote, at: restoreRoot.appendingPathComponent(name))
        defaults.set(remote.manifest.generation.uuidString, forKey: "backup.pendingGeneration")
        defaults.set(account, forKey: "backup.pendingAccount")
        defaults.set(defaults.data(forKey: "backup.bookmark"), forKey: "backup.pendingBookmark")
        defaults.set(name, forKey: "backup.pending")
        suspended = true
        pending?.cancel()
        status =
          "Restore prepared. Close and reopen Today to activate it. Current data remains available until then. Restored alarms are off; review them before enabling."
      } catch { status = "Restore failed; current data retained. \(error)" }
    }
    package static func validatePreferences(_ preferences: [String: Any]) throws {
      let strings: Set<String> = [
        "today.appearance", "today.setting.newReminderList", "today.setting.newEventCalendar",
        "today.setting.newAlarmSound", "today.setting.calendarStart", "today.setting.firstWeekday",
        "activity.setting.retention", "reminders.smartOrder", "reminders.smartHidden",
      ]
      let integers: Set<String> = [
        "today.setting.newEventAlert", "today.setting.newAlarmSnooze",
      ]
      let arrays: Set<String> = [
        "today.worldClock.cities"
      ]
      for (key, value) in preferences {
        guard preferenceKeys.contains(key) else { throw RecoveryArchive.Failure.corrupt }
        let valid: Bool
        if strings.contains(key) {
          valid = value is String
        } else if arrays.contains(key) {
          valid = value is [String]
        } else if integers.contains(key) {
          valid =
            (value as? NSNumber).map {
              CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue
            } ?? false
        } else {
          valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        }
        guard valid else { throw RecoveryArchive.Failure.corrupt }
      }
    }
    /// Runs at the shared app/intent boundary, before any source service is constructed.
    package static func activatePending(
      defaults: UserDefaults = .standard, root: URL = BackupController.root,
      identity: (() throws -> String)? = nil, testFolder: URL? = nil
    ) throws {
      guard let name = defaults.string(forKey: "backup.pending") else { return }
      guard UUID(uuidString: name) != nil,
        let generation = defaults.string(forKey: "backup.pendingGeneration").flatMap(
          UUID.init(uuidString:)),
        let account = defaults.string(forKey: "backup.pendingAccount"),
        try (identity ?? currentIdentity)() == account,
        defaults.string(forKey: "backup.account") == account,
        let bookmark = defaults.data(forKey: "backup.pendingBookmark"),
        defaults.data(forKey: "backup.bookmark") == bookmark
      else { throw RecoveryArchive.Failure.accountMismatch }
      let transport =
        testFolder.map { FolderRecoveryTransport(localDirectory: $0) }
        ?? FolderRecoveryTransport(bookmark: bookmark)
      let current = try transport.access(account: { try (identity ?? currentIdentity)() }) {
        folder, _ in
        try RecoveryGenerations.read(in: folder, account: account)
      }
      guard current?.manifest.generation == generation else {
        throw RecoveryGenerations.Failure.conflict
      }
      let directory = root.appendingPathComponent(name)
      guard let current else { throw RecoveryArchive.Failure.corrupt }
      for (file, bytes) in current.files {
        guard try Data(contentsOf: directory.appendingPathComponent(file)) == bytes else {
          throw RecoveryArchive.Failure.corrupt
        }
      }
      for file in ["default.store", "activity.sqlite", "preferences.json", "payload.json"] {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
        else { throw RecoveryArchive.Failure.corrupt }
      }
      let payload =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appendingPathComponent("payload.json")))
        as? [String: Any]
      guard payload?["payloadVersion"] as? Int == 1, payload?["appSchemaVersion"] as? Int == 1
      else { throw RecoveryArchive.Failure.unsupportedVersion }
      // Opening validates the candidate; the prior store path is never deleted or overwritten.
      _ = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(url: directory.appendingPathComponent("default.store")))
      let history = try ActivityStore(
        location: .file(directory.appendingPathComponent("activity.sqlite")))
      _ = try history.count()
      let preferences =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appendingPathComponent("preferences.json")))
        as? [String: Any]
      guard let preferences else { throw RecoveryArchive.Failure.corrupt }
      try validatePreferences(preferences)
      for key in preferenceKeys { defaults.set(preferences[key], forKey: key) }
      // Reset reconciliation bookkeeping, retaining system associations in restored records.
      for key in [
        "today.remindersSync.base", "today.remindersSync.listBase", "today.remindersSync.fp",
        "today.remindersSync.pendingDeletes", "today.remindersSync.pendingListDeletes",
        "today.remindersSync.occurrenceFences",
      ] { defaults.removeObject(forKey: key) }
      defaults.set(Date.now.timeIntervalSince1970, forKey: "today.remindersSync.uploadFrom")
      defaults.set(name, forKey: "backup.active")
      defaults.set(generation.uuidString, forKey: "backup.head")
      cancelRestore(defaults: defaults)
    }
  }
#endif

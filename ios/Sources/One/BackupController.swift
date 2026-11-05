#if os(iOS)
  import Foundation
  import SwiftData
  import UIKit
  import Observation
  import TodayData

  /// Folder grants and backup metadata are local; archive contents are explicitly selected.
  @MainActor @Observable
  package final class BackupController {
    package static let shared = BackupController()
    package private(set) var status = "Choose a folder to enable automatic backups."
    package private(set) var folder = UserDefaults.standard.string(forKey: "backup.folder") ?? ""
    package private(set) var lastSaved =
      UserDefaults.standard.object(forKey: "backup.saved") as? Date
    package private(set) var hasRemote = false
    private var remote: RecoveryArchive.Validated?
    private var transport: FolderRecoveryTransport?
    private var account = ""
    private var expected: UUID?
    private var session: PlannerSession?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var suspended = false
    private let defaults = UserDefaults.standard
    package static let preferenceKeys = [
      "today.appearance", "today.setting.showAlarmsInToday", "today.setting.jumpToNow",
      "today.setting.autoArchiveChats", "today.setting.travelTime", "today.setting.healthSummary",
      "today.setting.compressEmptyHours", "today.setting.dimPastDays", "today.setting.firstWeekday",
      "today.setting.weekNumbers", "today.setting.calendarStart", "today.setting.showSettle",
      "today.setting.showFreeTime", "today.setting.newReminderList",
      "today.setting.newEventCalendar",
      "today.setting.newEventAlert", "today.setting.newAlarmSnooze", "today.setting.newAlarmSound",
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
    private func identity() throws -> String {
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
      self.session = session
      if let bookmark = defaults.data(forKey: "backup.bookmark") {
        transport = FolderRecoveryTransport(bookmark: bookmark)
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
    package func select(_ url: URL) {
      do {
        let bookmark = try FolderRecoveryTransport.bookmark(for: url)
        let selected = FolderRecoveryTransport(bookmark: bookmark)
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
      suspended = remote?.manifest.generation != expected
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
        try discover()
        if !suspended { save() }
      } catch { status = "Backup unavailable; local data is safe. \(error)" }
    }
    package func save() {
      guard !busy, !suspended, let session, let transport else { return }
      busy = true
      defer { busy = false }
      do {
        guard try identity() == account else { throw RecoveryArchive.Failure.accountMismatch }
        if session.container.mainContext.hasChanges { try session.container.mainContext.save() }
        session.activity.recorder.flush()
        let count =
          try session.container.mainContext.fetchCount(FetchDescriptor<OneTask>())
          + session.container.mainContext.fetchCount(FetchDescriptor<ChatThread>())
          + session.container.mainContext.fetchCount(FetchDescriptor<OneEvent>())
          + session.container.mainContext.fetchCount(FetchDescriptor<OneAlarm>())
        guard count > 0 || expected != nil else {
          status = "Folder selected. Waiting for data before the first backup."
          return
        }
        let files = try Self.payload(
          container: session.container,
          activityURL: Self.active?.appendingPathComponent("activity.sqlite")
            ?? ActivityStore.defaultURL(), defaults: defaults)
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
    package static func payload(container: ModelContainer, activityURL: URL, defaults: UserDefaults)
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
      let preferences = Dictionary(
        uniqueKeysWithValues: Self.preferenceKeys.compactMap { key in
          defaults.object(forKey: key).map { (key, $0) }
        })
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
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try RecoveryArchive.stage(remote, at: Self.root.appendingPathComponent(name))
        defaults.set(name, forKey: "backup.pending")
        suspended = true
        pending?.cancel()
        status =
          "Restore prepared. Close and reopen Today to activate it. Current data remains available until then. Restored alarms are off; review them before enabling."
      } catch { status = "Restore failed; current data retained. \(error)" }
    }
    /// Runs at the shared app/intent boundary, before any source service is constructed.
    package static func activatePending() throws {
      let defaults = UserDefaults.standard
      guard let name = defaults.string(forKey: "backup.pending") else { return }
      let directory = root.appendingPathComponent(name)
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
        as? [String: Any] ?? [:]
      for key in preferenceKeys { defaults.set(preferences[key], forKey: key) }
      // Reset reconciliation bookkeeping, retaining system associations in restored records.
      for key in [
        "today.remindersSync.base", "today.remindersSync.listBase", "today.remindersSync.fp",
        "today.remindersSync.pendingDeletes", "today.remindersSync.pendingListDeletes",
        "today.remindersSync.occurrenceFences",
      ] { defaults.removeObject(forKey: key) }
      defaults.set(Date.now.timeIntervalSince1970, forKey: "today.remindersSync.uploadFrom")
      defaults.set(name, forKey: "backup.active")
      defaults.removeObject(forKey: "backup.pending")
    }
  }
#endif

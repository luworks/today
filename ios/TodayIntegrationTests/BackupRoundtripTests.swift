#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayData
  import TodayCore
  import TodayTestSupport
  @testable import One

  @MainActor
  struct BackupRoundtripTests {
    @Test func controllerRestoreLifecycle() throws {
      for kind in ["history", "list", "preferences", "empty"] {
        try restoreLifecycle(kind: kind)
      }
    }
    private func restoreLifecycle(kind: String) throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let suite = "RecoveryLifecycle." + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let container = try ModelContainer(
        for: BackupController.schema,
        configurations: ModelConfiguration(url: root.appendingPathComponent("source.store")))
      let historyURL = root.appendingPathComponent("activity.sqlite")
      let history = try ActivityStore(location: .file(historyURL))
      let runtime = PlannerRuntime(
        now: { .now }, nextID: { UUID() }, calendar: .current, locale: .current)
      let activity = ActivityCenter(store: history, defaults: defaults, runtime: runtime)
      defer { activity.dispose() }
      defaults.register(defaults: ["today.setting.jumpToNow": true])
      if kind == "history" {
        try history.insert([ActivityEvent(kind: "change.completed", actor: "user")])
      }
      if kind == "list" { container.mainContext.insert(OneList(name: "Saved list")) }
      if kind == "preferences" { defaults.set(false, forKey: "today.setting.jumpToNow") }
      let folder = root.appendingPathComponent("folder")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      func controller() -> BackupController {
        let c = BackupController(
          defaults: defaults, restoreRoot: root, identity: { "test" }, testFolder: folder,
          preferencesDomain: suite)
        c.bind(container: container, activity: activity, activityURL: historyURL)
        c.select(folder)
        return c
      }
      let first = controller()
      first.save()
      if kind == "empty" {
        #expect(try RecoveryGenerations.read(in: folder, account: "test") == nil)
        return
      }
      let generation = try #require(defaults.string(forKey: "backup.head"))
      let restored = controller()
      restored.save()  // Unacknowledged existing head remains untouched.
      #expect(defaults.string(forKey: "backup.head") == nil)
      restored.stageRestore()
      try BackupController.activatePending(
        defaults: defaults, root: root, identity: { "test" }, testFolder: folder)
      #expect(defaults.string(forKey: "backup.head") == generation)
      #expect(defaults.string(forKey: "backup.active") != nil)
      let fresh = try ModelContainer(
        for: BackupController.schema,
        configurations: ModelConfiguration(
          url: root.appendingPathComponent(defaults.string(forKey: "backup.active")!)
            .appendingPathComponent("default.store")))
      let resumed = BackupController(
        defaults: defaults, restoreRoot: root, identity: { "test" }, testFolder: folder,
        preferencesDomain: suite)
      resumed.bind(container: fresh, activity: activity, activityURL: historyURL)
      fresh.mainContext.insert(OneTask(title: "After restore"))
      resumed.retry()
      #expect(defaults.string(forKey: "backup.head") != generation)
      let next = controller()
      next.stageRestore()
      activity.clear()
      #expect(defaults.string(forKey: "backup.pending") == nil)
      let active = defaults.string(forKey: "backup.active")
      try BackupController.activatePending(
        defaults: defaults, root: root, identity: { "test" }, testFolder: folder)
      #expect(defaults.string(forKey: "backup.active") == active)
      #expect(try history.count() == 0)
      let services = try PlannerTestServices(
        container: fresh, defaults: defaults, runtime: runtime, arguments: [],
        activityStore: history)
      defer { services.dispose() }
      let deleting = controller()
      deleting.stageRestore()
      #expect(
        DataReset.run(
          fresh.mainContext, reminders: services.reminders, ledger: services.ledger,
          inbox: FileShareInbox(url: nil),
          focus: TodayFocus(ledger: services.ledger, runtime: runtime)))
      try BackupController.activatePending(
        defaults: defaults, root: root, identity: { "test" }, testFolder: folder)
      #expect(try fresh.mainContext.fetchCount(FetchDescriptor<OneTask>()) == 0)
      #expect(try fresh.mainContext.fetchCount(FetchDescriptor<OneList>()) == 0)
      #expect(try history.count() == 0)
      deleting.stageRestore()
      let oldHead = try #require(try RecoveryGenerations.read(in: folder, account: "test"))
      let encoded = try RecoveryArchive.encode(files: oldHead.files, account: "test")
      _ = try RecoveryGenerations.publish(
        encoded, in: folder, account: "test", expected: oldHead.manifest.generation,
        localHasUserData: true)
      #expect(throws: (any Error).self) {
        try BackupController.activatePending(
          defaults: defaults, root: root, identity: { "test" }, testFolder: folder)
      }
      #expect(defaults.string(forKey: "backup.active") == active)
      try BackupController.validatePreferences(["today.setting.jumpToNow": false])
      #expect(throws: (any Error).self) {
        try BackupController.validatePreferences(["today.setting.jumpToNow": "false"])
      }
    }
    @Test func productDatabaseHistoryAndPreferencesSurviveTwoOpens() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("source.store")
      let container = try ModelContainer(
        for: BackupController.schema, configurations: ModelConfiguration(url: url))
      let task = OneTask(title: "Recovery reminder", note: "Keep this note")
      task.externalID = "existing-apple-reminder"
      container.mainContext.insert(task)
      container.mainContext.insert(ChatThread(title: "Recovery chat", messages: []))
      try container.mainContext.save()
      let historyURL = root.appendingPathComponent("source.activity.sqlite")
      let history = try ActivityStore(location: .file(historyURL))
      var event = ActivityEvent(kind: "change.completed", actor: "user")
      event.title = "Historical completion"
      event.snapshot = Data("historical snapshot".utf8)
      try history.insert([event])
      let suite = "backup-test-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(false, forKey: "today.setting.jumpToNow")
      let files = try BackupController.payload(
        container: container, activityURL: historyURL, defaults: defaults, preferencesDomain: suite)
      let folder = root.appendingPathComponent("folder")
      let encoded = try RecoveryArchive.encode(files: files, account: "local-test")
      let id = try RecoveryGenerations.publish(
        encoded, in: folder, account: "local-test", expected: nil, localHasUserData: true)
      let archive = try #require(try RecoveryGenerations.read(in: folder, account: "local-test"))
      let restored = root.appendingPathComponent("restored")
      try RecoveryArchive.stage(archive, at: restored)
      for _ in 0..<2 {
        try autoreleasepool {
          let fresh = try ModelContainer(
            for: BackupController.schema,
            configurations: ModelConfiguration(
              url: restored.appendingPathComponent("default.store")))
          let tasks = try fresh.mainContext.fetch(FetchDescriptor<OneTask>())
          #expect(tasks.count == 1)
          #expect(tasks.first?.title == "Recovery reminder")
          #expect(tasks.first?.note == "Keep this note")
          #expect(tasks.first?.externalID == "existing-apple-reminder")
          #expect(
            try fresh.mainContext.fetch(FetchDescriptor<ChatThread>()).first?.title
              == "Recovery chat")
          let restoredHistory = try ActivityStore(
            location: .file(restored.appendingPathComponent("activity.sqlite")))
          #expect(try restoredHistory.count() == 1)
          #expect(try restoredHistory.page(ActivityQuery()).first?.title == "Historical completion")
          let prefs =
            try JSONSerialization.jsonObject(
              with: Data(contentsOf: restored.appendingPathComponent("preferences.json")))
            as? [String: Bool]
          #expect(prefs?["today.setting.jumpToNow"] == false)
        }
      }
      // Neither a fresh empty store nor an unacknowledged nonempty store may replace this head.
      #expect(throws: (any Error).self) {
        try RecoveryGenerations.publish(
          encoded, in: folder, account: "local-test", expected: nil, localHasUserData: false)
      }
      #expect(throws: (any Error).self) {
        try RecoveryGenerations.publish(
          encoded, in: folder, account: "local-test", expected: nil, localHasUserData: true)
      }
      #expect(
        try RecoveryGenerations.read(in: folder, account: "local-test")?.manifest.generation == id)
      try Data("damaged".utf8).write(
        to: folder.appendingPathComponent(id.uuidString + ".todaybackup"))
      #expect(throws: (any Error).self) {
        try RecoveryGenerations.read(in: folder, account: "local-test")
      }
    }
  }
#endif

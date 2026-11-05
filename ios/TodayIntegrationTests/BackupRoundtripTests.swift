#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayData
  @testable import One

  @MainActor
  struct BackupRoundtripTests {
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
        container: container, activityURL: historyURL, defaults: defaults)
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

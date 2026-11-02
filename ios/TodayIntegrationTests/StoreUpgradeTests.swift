#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  @testable import One

  /// A store written before `Habit`, `LedgerEntry`, `AIGrant` and `OneTask.plannedStart` were deleted (November 2026) opens
  /// with the current schema: SwiftData's lightweight migration drops the removed tables and column and keeps the rest.
  /// (If a store ever cannot be opened, `OneStore` starts a fresh one instead of crashing.)
  @MainActor
  struct StoreUpgradeTests {
    @Test
    func oldStoreOpensWithCurrentSchema() throws {
      let fixture = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("swiftdata-upgrade", isDirectory: true)
        .appendingPathComponent("old.store")
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("One-StoreUpgrade-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = directory.appendingPathComponent("old.store")
      try FileManager.default.copyItem(at: fixture, to: store)

      try check(store)  // migrates the old store
      try check(store)  // and the migrated store opens again
    }

    private func check(_ store: URL) throws {
      try autoreleasepool {
        let schema = Schema([
          OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, ChatThread.self,
          ShareImportReceipt.self,
        ])
        let container = try ModelContainer(
          for: schema,
          configurations: [
            ModelConfiguration(
              schema: schema, url: store, allowsSave: true, cloudKitDatabase: .none)
          ])
        let c = ModelContext(container)
        let tasks = try c.fetch(FetchDescriptor<OneTask>())
        let events = try c.fetch(FetchDescriptor<OneEvent>())
        let alarms = try c.fetch(FetchDescriptor<OneAlarm>())
        let lists = try c.fetch(FetchDescriptor<OneList>())
        let threads = try c.fetch(FetchDescriptor<ChatThread>())
        let receipts = try c.fetch(FetchDescriptor<ShareImportReceipt>())
        let counts: [Int] = [
          tasks.count, events.count, alarms.count, lists.count, threads.count, receipts.count,
        ]
        #expect(counts == [3, 2, 2, 2, 1, 1])

        let task = try #require(tasks.first { $0.title == "Synthetic recurring work" })
        let meeting = try #require(events.first { $0.title == "Synthetic meeting" })
        let wake = try #require(alarms.first { $0.label == "Synthetic wake" })
        let thread = try #require(threads.first)
        let listNames: [String] = lists.map(\.name)
        #expect(task.listName == "Synthetic Work")
        #expect(listNames.contains(task.listName))
        let checklistIDs: [UUID] = task.checklist.map(\.id)
        #expect(checklistIDs == [Self.uid(10), Self.uid(11)])
        #expect(task.due != nil)
        let itemIDs: [Data] = thread.items.map(Self.encoded)
        let expectedIDs: [Data] = [
          Self.encoded(task.persistentModelID), Self.encoded(meeting.persistentModelID),
          Self.encoded(wake.persistentModelID),
        ]
        #expect(itemIDs == expectedIDs)
        let messageIDs: [UUID] = thread.messages.map(\.id)
        #expect(messageIDs == [Self.uid(60), Self.uid(61)])
        #expect(thread.cards.count == 1)
        let sharedID: UUID? = receipts.first?.sharedID
        #expect(sharedID == Self.uid(50))
      }
    }

    private static func uid(_ n: Int) -> UUID {
      UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// Compares persistent IDs by their complete encoding (decoded IDs don't compare reliably with `==`).
    private static func encoded(_ id: PersistentIdentifier) -> Data {
      (try? JSONEncoder().encode(id)) ?? Data()
    }
  }
#endif

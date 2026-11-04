#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayCore
  @testable import One

  @MainActor
  struct LiveEmptyStoreTests {
    @Test func persistentStartupDoesNotInventPlannerRecordsOnRelaunch() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self,
        ChatThread.self, ShareImportReceipt.self,
      ])
      let configuration = ModelConfiguration(url: directory.appendingPathComponent("empty.store"))
      for _ in 0..<2 {
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        ListActions.ensureLists(
          in: context,
          runtime: PlannerRuntime(
            now: { .now }, nextID: { UUID() }, calendar: .current, locale: .current))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<OneTask>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OneEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OneAlarm>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OneList>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 0)
      }
    }
  }
#endif

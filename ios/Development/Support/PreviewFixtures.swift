import FeatureReminders
import One

#if DEBUG
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import FeatureClock
  import FeatureHealth
  import SwiftUI
  import SwiftData

  /// Small versioned UI fixtures. Never open OneStore or the user Activity database.
  @MainActor
  enum PreviewFixtures {
    static var isAxe: Bool { ProcessInfo.processInfo.environment["AXE_PREVIEW_SOCKET_PATH"] != nil }

    static let reminders: ModelContainer = {
      do {
        let container = try ModelContainer(
          for: OneTask.self, OneEvent.self, OneAlarm.self, OneList.self,
          ChatThread.self, ShareImportReceipt.self,
          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        for (index, name) in ["Work", "Home", "Travel"].enumerated() {
          context.insert(OneList(name: name, colorIndex: index * 3, order: index))
        }
        for (title, list, flagged) in [
          ("Review the design", "Work", true),
          ("Book train tickets", "Travel", false),
          ("Water the plants", "Home", false),
        ] {
          let task = OneTask(title: title, due: Calendar.current.startOfDay(for: .now))
          task.listName = list
          task.flagged = flagged
          context.insert(task)
        }
        try context.save()
        return container
      } catch { fatalError("Preview fixture failed: \(error)") }
    }()

    static let healthNow = Date(timeIntervalSince1970: 1_792_339_200)
  }
#endif

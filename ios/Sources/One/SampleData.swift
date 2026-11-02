#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData

  /// A few items around today so the first launch isn't empty. Inserted once; Delete all data removes them.
  package enum SampleData {
    package static func resetFlags() {
      UserDefaults.standard.removeObject(forKey: "today.sampleData.v1")
    }

    package static func insertIfNeeded(_ context: ModelContext) {
      let key = "today.sampleData.v1"
      guard !UserDefaults.standard.bool(forKey: key) else { return }
      UserDefaults.standard.set(true, forKey: key)

      let cal = Calendar.current
      let today = cal.startOfDay(for: .now)
      func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        let d = cal.date(byAdding: .day, value: dayOffset, to: today) ?? today
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
      }

      let events: [(String, Date, Int)] = [
        ("Product sync", at(0, 9, 0), 25),
        ("Lunch with Priya", at(0, 12, 15), 45),
        ("Dentist", at(0, 15, 0), 30),
        ("Weekly review", at(1, 10, 0), 30),
      ]
      for (title, start, minutes) in events {
        context.insert(OneEvent(title: title, start: start, durationMinutes: minutes))
      }
      let standup = OneEvent(title: "Standup", start: at(0, 9, 45), durationMinutes: 15)
      standup.repeatRule = RepeatRule.weekdays.rawValue
      context.insert(standup)
      let offsite = OneEvent(title: "Team offsite", start: at(2, 0, 0), durationMinutes: 2 * 1440)
      offsite.isAllDay = true
      context.insert(offsite)

      let demo = OneTask(
        title: "Prepare the demo", durationMinutes: 45, due: at(1, 17, 0))
      demo.listName = "Work"
      demo.flagged = true
      demo.checklist = [
        ChecklistItem(title: "Outline", done: true), ChecklistItem(title: "Slides"),
        ChecklistItem(title: "Rehearse"),
      ]
      context.insert(demo)
      context.insert(OneTask(title: "Write up design review notes", due: at(0, 16, 0)))
      let milk = OneTask(title: "Buy milk", due: today)
      milk.listName = "Home"
      milk.tags = ["errands"]
      context.insert(milk)
      let plants = OneTask(title: "Water the plants", due: today)
      plants.listName = "Home"
      plants.repeatRule = RepeatRule.weekly.rawValue
      context.insert(plants)
      context.insert(OneTask(title: "Pay studio invoice", due: at(-1, 17, 0)))
      context.insert(OneTask(title: "Read that design article"))
    }
  }
#endif

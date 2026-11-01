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
  import Foundation
  import SwiftData

  /// Debug-only: loads the test dataset (`tests/fixtures/today-dataset.json`) into a fresh in-memory store, so every launch
  /// starts from the same chats, reminders, events and alarms. Launch with `-uiTesting -dataset <path>`; without `-uiTesting`
  /// the file is ignored, so it can never be synced into Apple Calendar or Apple Reminders.
  enum TestDataset {
    /// Linked ids of dataset events with synthetic attendees, and their counts (`TestCalendarService.audiences`).
    nonisolated(unsafe) static var audiences: [String: Int] = [:]
    struct When: Decodable {
      let day: Int
      let time: String?
    }
    struct List: Decodable {
      let name: String
      let color: Int?
    }
    struct Check: Decodable {
      let title: String
      let done: Bool?
    }
    struct Reminder: Decodable {
      let title: String
      let list: String?
      let note: String?
      let due: When?
      let planned: When?
      let minutes: Int?
      let flagged: Bool?
      let done: Bool?
      let `repeat`: String?
      let tags: [String]?
      let checklist: [Check]?
      let ringsAsAlarm: Bool?
    }
    struct Event: Decodable {
      let title: String
      let start: When
      let minutes: Int
      let allDay: Bool?
      let `repeat`: String?
      /// Synthetic attendee count: the event gets a linked id the test calendar reports attendees for.
      let attendees: Int?
    }
    struct Alarm: Decodable {
      let time: String
      let label: String?
      let weekdays: [Int]?
      let on: Bool?
      let snooze: Bool?
    }
    struct Chat: Decodable {
      let title: String
      let hoursAgo: Double
      let archived: Bool?
      let messages: [[String]]
    }
    struct File: Decodable {
      let version: Int
      let lists: [List]?
      let reminders: [Reminder]
      let events: [Event]
      let alarms: [Alarm]
      let chats: [Chat]
    }

    /// The path given with `-dataset`, only together with `-uiTesting`.
    static var requestedPath: String? {
      let args = ProcessInfo.processInfo.arguments
      guard args.contains("-uiTesting"), let i = args.firstIndex(of: "-dataset"), i + 1 < args.count
      else { return nil }
      return args[i + 1]
    }

    static func load(
      path: String, into context: ModelContext, now: Date = .now, calendar cal: Calendar = .current
    ) throws {
      let file = try JSONDecoder().decode(
        File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      let today = cal.startOfDay(for: now)
      func date(_ w: When?) -> (date: Date, timed: Bool)? {
        guard let w, let day = cal.date(byAdding: .day, value: w.day, to: today) else { return nil }
        guard let t = w.time else { return (day, false) }
        let hm = t.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2,
          let d = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day)
        else { return (day, false) }
        return (d, true)
      }

      for (i, l) in (file.lists ?? []).enumerated() {
        context.insert(
          OneList(name: l.name, colorIndex: l.color ?? i, symbol: "list.bullet", order: i))
      }
      for r in file.reminders {
        let t = OneTask(
          title: r.title, note: r.note ?? "",
          durationMinutes: r.minutes ?? 25, due: (date(r.due) ?? date(r.planned))?.date)
        t.listName = r.list ?? ""
        t.flagged = r.flagged ?? false
        t.tags = r.tags ?? []
        t.repeatRule = r.repeat.flatMap { RepeatRule(rawValue: $0)?.rawValue }
        t.checklist = (r.checklist ?? []).map {
          ChecklistItem(title: $0.title, done: $0.done ?? false)
        }
        if r.ringsAsAlarm == true {
          t.reminderOffsetMinutes = 0
          t.ringsAsAlarm = true
        }
        context.insert(t)
        if r.done == true { t.toggleDone() }
      }
      for e in file.events {
        guard let start = date(e.start) else { continue }
        let event = OneEvent(title: e.title, start: start.date, durationMinutes: e.minutes)
        event.isAllDay = e.allDay ?? false
        event.repeatRule = e.repeat.flatMap { RepeatRule(rawValue: $0)?.rawValue }
        if let n = e.attendees, n > 0 {
          let id = "dataset-attendees-\(audiences.count + 1)"
          event.externalID = id
          audiences[id] = n
        }
        context.insert(event)
      }
      for a in file.alarms {
        let hm = a.time.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { continue }
        let alarm = OneAlarm(
          hour: hm[0], minute: hm[1], label: a.label ?? "", weekdays: a.weekdays ?? [],
          snooze: a.snooze ?? true)
        alarm.isOn = a.on ?? true
        context.insert(alarm)
      }
      for c in file.chats {
        let when = now.addingTimeInterval(-c.hoursAgo * 3600)
        let messages = c.messages.compactMap { pair -> ChatMessage? in
          guard pair.count == 2, let role = ChatMessage.Role(rawValue: pair[0]) else { return nil }
          return ChatMessage(role: role, text: pair[1], timestamp: nil)
        }
        let thread = ChatThread(
          title: c.title, messages: messages, createdAt: when, updatedAt: when)
        thread.archived = c.archived ?? false
        context.insert(thread)
      }
      try context.save()
    }
  }
#endif

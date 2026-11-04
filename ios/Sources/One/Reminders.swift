#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData
  import UserNotifications

  /// Local notifications for timed tasks and events: one per item, with Done / Snooze / Tomorrow actions.
  /// One alert per item: an item that Apple already alerts for (a synced reminder's due time) or that rings as an alarm
  /// (AlarmKit) gets no notification from us. Snoozing only moves the reminder, never the task;
  /// stopping a reminder never completes the task (only Done does).
  @MainActor
  package final class Reminders: NSObject, NotificationService, UNUserNotificationCenterDelegate {

    package static let taskCategory = "ONE_TASK"
    package static let eventCategory = "ONE_EVENT"
    package enum Action: String {
      case done = "DONE"
      case snooze10 = "SNOOZE_10"
      case snooze60 = "SNOOZE_60"
      case tomorrow = "TOMORROW"
    }

    /// iOS keeps at most 64 pending requests per app.
    package static let maxPending = 60
    private static let snoozePrefix = "snooze-"

    private let center: UNUserNotificationCenter
    private let alarms: any AlarmService
    private let reminders: any ReminderService
    private let ledger: Ledger
    private let runtime: PlannerRuntime

    package init(
      center: UNUserNotificationCenter, alarms: any AlarmService, reminders: any ReminderService,
      ledger: Ledger, runtime: PlannerRuntime
    ) {
      self.center = center
      self.alarms = alarms
      self.reminders = reminders
      self.ledger = ledger
      self.runtime = runtime
      super.init()
    }

    package func dispose() {
      disposed = true
      if center.delegate === self { center.delegate = nil }
      container = nil
    }
    private var container: ModelContainer?
    private var disposed = false

    package func configure(_ container: ModelContainer) {
      guard !disposed, self.container == nil else { return }
      self.container = container
      center.delegate = self
      let done = UNNotificationAction(identifier: Action.done.rawValue, title: "Done", options: [])
      let s10 = UNNotificationAction(
        identifier: Action.snooze10.rawValue, title: "Snooze 10 min", options: [])
      let s60 = UNNotificationAction(
        identifier: Action.snooze60.rawValue, title: "Snooze 1 hour", options: [])
      let tomorrow = UNNotificationAction(
        identifier: Action.tomorrow.rawValue, title: "Move to tomorrow", options: [])
      var categories: Set<UNNotificationCategory> = [
        UNNotificationCategory(
          identifier: "TODAY_REMINDER_OFF", actions: [done, tomorrow], intentIdentifiers: [])
      ]
      for minutes in AlarmPlan.snoozeChoices {
        categories.insert(
          UNNotificationCategory(
            identifier: "TODAY_REMINDER_\(minutes)",
            actions: [
              done,
              UNNotificationAction(
                identifier: "SNOOZE_CUSTOM", title: "Snooze \(minutes) min", options: []), tomorrow,
            ], intentIdentifiers: []))
      }
      categories.formUnion([
        UNNotificationCategory(
          identifier: Self.taskCategory, actions: [done, s10, s60, tomorrow], intentIdentifiers: []),
        UNNotificationCategory(
          identifier: Self.eventCategory, actions: [s10], intentIdentifiers: []),
      ])
      center.setNotificationCategories(categories)
    }

    // MARK: Permission

    package func authorizationStatus() async -> UNAuthorizationStatus {
      await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    package func requestPermission() async -> Bool {
      guard !disposed else { return false }
      let granted =
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      await resync()
      return granted
    }

    // MARK: Scheduling

    /// Rebuilds all pending reminders from the current data. Cheap; call after any change.
    package func resync() async {
      guard !disposed, let context = container?.mainContext else { return }
      let status = await authorizationStatus()
      guard status == .authorized || status == .provisional else { return }

      let now = runtime.now()
      guard !disposed, !Task.isCancelled else { return }
      let horizon = now.addingTimeInterval(14 * 24 * 3600)
      let tasks =
        (try? context.fetch(FetchDescriptor<OneTask>(predicate: #Predicate { !$0.isDone }))) ?? []
      let events = (try? context.fetch(FetchDescriptor<OneEvent>())) ?? []

      // "Ring as alarm" replaces the notification when AlarmKit can ring it; otherwise the notification is the fallback.
      let rings = alarms.authorization == .authorized
      var requests: [(Date, UNNotificationRequest)] = []
      for task in tasks {
        guard let fire = plannerReminderDate(task, runtime: runtime), fire > now, fire < horizon
        else { continue }
        if rings, task.ringsAsAlarm { continue }
        // A synced reminder with only a due time is alerted by Apple Reminders itself; ours would be a duplicate.
        if task.externalID != nil { continue }
        let id = Self.key(task.persistentModelID)
        let when = task.due.map { "Due " + plannerDayLabel($0, runtime: runtime) } ?? ""
        requests.append(
          (
            fire,
            request(
              id: "\(id)#0", title: task.title, body: when,
              category: ReminderAlert(rawValue: task.reminderAlert)?.category ?? Self.taskCategory,
              key: id,
              at: fire, alert: ReminderAlert(rawValue: task.reminderAlert))
          ))
      }
      for event in events {
        guard let fire = plannerReminderDate(event, runtime: runtime), fire > now, fire < horizon
        else { continue }
        if rings, event.ringsAsAlarm { continue }
        let id = Self.key(event.persistentModelID)
        let body =
          event.start.formatted(date: .omitted, time: .shortened)
          + " · \(event.durationMinutes) min"
        requests.append(
          (
            fire,
            request(
              id: "\(id)#0", title: event.title, body: body, category: Self.eventCategory, key: id,
              at: fire)
          ))
      }

      let pending = await center.pendingNotificationRequests()
      let snoozed = pending.filter { $0.identifier.hasPrefix(Self.snoozePrefix) }
      center.removePendingNotificationRequests(
        withIdentifiers: pending.map(\.identifier).filter { !$0.hasPrefix(Self.snoozePrefix) })
      for (_, r) in requests.sorted(by: { $0.0 < $1.0 }).prefix(
        max(0, Self.maxPending - snoozed.count))
      {
        try? await center.add(r)
      }
      try? await center.setBadgeCount(
        tasks.filter { $0.due.map { $0 < runtime.calendar.startOfDay(for: now) } ?? false }.count)
    }

    private func request(
      id: String, title: String, body: String, category: String, key: String, at date: Date,
      alert: ReminderAlert? = nil
    ) -> UNNotificationRequest {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if let tone = alert.flatMap({ AlarmSound.named($0.sound) }) {
        content.sound = UNNotificationSound(named: UNNotificationSoundName(tone.file + ".caf"))
      } else {
        content.sound = .default
      }
      content.categoryIdentifier = category
      content.threadIdentifier = key
      content.userInfo = ["key": key]
      content.interruptionLevel = .timeSensitive
      let parts = runtime.calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date)
      return UNNotificationRequest(
        identifier: id, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    private static func key(_ id: PersistentIdentifier) -> String {
      (try? JSONEncoder().encode(id)).map { $0.base64EncodedString() } ?? UUID().uuidString
    }

    private static func identifier(from key: String) -> PersistentIdentifier? {
      Data(base64Encoded: key).flatMap {
        try? JSONDecoder().decode(PersistentIdentifier.self, from: $0)
      }
    }

    // MARK: Notification delegate

    package nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
      [.banner, .sound, .list]
    }

    package nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse
    ) async {
      let action = response.actionIdentifier
      let content = response.notification.request.content
      let key = content.userInfo["key"] as? String ?? ""
      let title = content.title
      let body = content.body
      let category = content.categoryIdentifier
      await handle(action: action, key: key, title: title, body: body, category: category)
    }

    private func handle(action: String, key: String, title: String, body: String, category: String)
      async
    {
      guard !disposed else { return }
      let alert: ReminderAlert? = {
        guard let id = Self.identifier(from: key),
          let task = container?.mainContext.model(for: id) as? OneTask
        else { return nil }
        return ReminderAlert(rawValue: task.reminderAlert)
      }()
      let customFire =
        action == "SNOOZE_CUSTOM"
        ? alert?.snoozeMinutes.map { runtime.now().addingTimeInterval(Double($0 * 60)) } : nil
      if let fire = customFire ?? ReminderPlan.snoozed(action, now: runtime.now()) {
        let r = request(
          id: Self.snoozePrefix + runtime.nextID().uuidString, title: title, body: body,
          category: category, key: key, at: fire, alert: alert)
        do { try await center.add(r) } catch { return }
        await clearDelivered(key: key)
        return
      }

      guard !disposed, let context = container?.mainContext, let id = Self.identifier(from: key)
      else { return }
      guard let task = context.model(for: id) as? OneTask else { return }
      switch Action(rawValue: action) {
      case .done:
        if !task.isDone {
          TaskActions.toggleDone(
            task, context: context, toast: nil, reminders: reminders, ledger: ledger,
            runtime: runtime, channel: .notification)
        }
      case .tomorrow:
        let cal = runtime.calendar
        // Tomorrow, at the same time of day (a date-only reminder stays date-only).
        let time = task.due.map { cal.dateComponents([.hour, .minute], from: $0) }
        let new = cal.date(byAdding: .day, value: 1, to: runtime.now()).flatMap {
          cal.date(
            bySettingHour: time?.hour ?? 0, minute: time?.minute ?? 0, second: 0, of: $0)
        }
        TaskActions.setDue(
          task, to: new, context: context, ledger: ledger, channel: .notification)
      default:
        return
      }
      try? context.save()
      await clearDelivered(key: key)
      await removeSnoozes(key: key)
      await resync()
    }

    private func clearDelivered(key: String) async {
      let delivered = await center.deliveredNotifications()
      center.removeDeliveredNotifications(
        withIdentifiers:
          delivered
          .filter { $0.request.content.userInfo["key"] as? String == key }
          .map(\.request.identifier))
    }

    private func removeSnoozes(key: String) async {
      let pending = await center.pendingNotificationRequests()
      center.removePendingNotificationRequests(
        withIdentifiers:
          pending
          .filter { $0.content.userInfo["key"] as? String == key }
          .map(\.identifier))
    }
  }

  /// Runtime-aware equivalents of the persisted models' notification projections. No schema is changed.
  @MainActor
  package func plannerReminderDate(_ task: OneTask, runtime: PlannerRuntime) -> Date? {
    guard let offset = task.reminderOffsetMinutes else { return nil }
    let timedDue = task.due.flatMap { due -> Date? in
      runtime.calendar.dateComponents([.hour, .minute], from: due)
        == DateComponents(hour: 0, minute: 0) ? nil : due
    }
    return timedDue?.addingTimeInterval(TimeInterval(-offset * 60))
  }

  @MainActor
  package func plannerReminderDate(_ event: OneEvent, runtime: PlannerRuntime) -> Date? {
    guard let offset = event.reminderOffsetMinutes else { return nil }
    let now = runtime.now()
    let start = now.addingTimeInterval(-60)
    let interval = DateInterval(start: start, duration: 400 * 86400)
    guard
      var next = event.occurrences(in: interval, calendar: runtime.calendar).first(where: {
        $0 > start
      })
    else { return nil }
    if event.isAllDay {
      next = runtime.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
    }
    return next.addingTimeInterval(TimeInterval(-offset * 60))
  }

#endif

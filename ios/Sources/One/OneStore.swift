#if os(iOS)
  import Foundation
  import SwiftData
  import EventKit
  import UserNotifications
  import WidgetKit
  import os
  import TodayCore
  import TodayData
  import TodayShared
  import TodayPlatform

  /// Framework boundary shared by the live app and its App Intents, whichever starts first.
  @MainActor
  public enum OneStore {
    public static var container: ModelContainer { session.container }

    @discardableResult
    public static func start() -> ModelContainer { session.container }

    package static let session: PlannerSession = {
      do {
        let defaults = UserDefaults.standard
        let runtime = PlannerRuntime(
          now: { Date.now }, nextID: { UUID() },
          calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        let (container, wasReset) = try OneStore.openContainer()
        let calendar = CalendarSync(
          defaults: defaults, runtime: runtime, arguments: [], makeStore: { EKEventStore() })
        let reminders = RemindersSync(
          defaults: defaults, runtime: runtime, arguments: [], makeStore: { EKEventStore() })
        let driver = Ringer(defaults: defaults, runtime: runtime)
        let alarms = AlarmCenter(driver: driver)
        let timers = TimerController(
          defaults: defaults, runtime: runtime, driver: driver,
          donate: { TimerIntentSupport.donate(seconds: $0) })
        let store = try ActivityStore.openOrRecover(at: ActivityStore.defaultURL())
        let activity = ActivityCenter(store: store, defaults: defaults, runtime: runtime)
        let ledger = Ledger(activity: activity, reminders: reminders, runtime: runtime)
        let notifications = Reminders(
          center: .current(), alarms: alarms, reminders: reminders,
          ledger: ledger, runtime: runtime)
        let travel = TravelTimes(defaults: defaults, runtime: runtime)
        let sound = SoundPreview()
        let actions = PlannerActions(
          calendar: calendar, reminders: reminders, alarms: alarms,
          ledger: ledger, runtime: runtime, defaults: defaults)
        let widget = WidgetFeed(
          container: container, calendar: calendar, reminders: reminders,
          runtime: runtime, enabled: true,
          travel: { travel.widgetFields(eventID: $0, start: $1, isAllDay: $2, place: $3, now: $4) },
          save: { $0.save() }, reload: { WidgetCenter.shared.reloadAllTimelines() })
        travel.didUpdateEstimate = { [weak widget] in widget?.rewriteFromStore() }
        // A fresh store must re-import from Apple Reminders, never mirror the empty store there.
        if wasReset { reminders.forgetLink() }
        reminders.configure(container, ledger: ledger)
        notifications.configure(container)
        widget.registerBackgroundRefresh()
        return PlannerSession(
          container: container, defaults: defaults, runtime: runtime, calendar: calendar,
          reminders: reminders, alarms: alarms, timers: timers, notifications: notifications,
          activity: activity, ledger: ledger, actions: actions, travel: travel,
          soundPreview: sound, widget: widget,
          inbox: FileShareInbox(url: ShareInbox.fileURL)
        ) {
          calendar.dispose()
          reminders.dispose()
          notifications.dispose()
          travel.dispose()
          sound.stop()
          ledger.dispose()
          activity.dispose()
        }
      } catch {
        fatalError("Could not open the data store: \(error)")
      }
    }()

    /// Opens the default store. SwiftData migrates removed models and fields by itself; when a store still cannot be
    /// opened, it is deleted and a fresh one starts (owner decision 2026-11-01: losing local-only data is accepted; Apple
    /// Calendar and Apple Reminders are the source of truth and sync back in).
    private static func openContainer() throws -> (ModelContainer, wasReset: Bool) {
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, ChatThread.self,
        ShareImportReceipt.self,
      ])
      let configuration = ModelConfiguration()
      do {
        return (try ModelContainer(for: schema, configurations: configuration), false)
      } catch {
        Logger(subsystem: "com.luworks.today", category: "store").error(
          "Store could not be opened, starting fresh: \(String(describing: error), privacy: .public)"
        )
        let path = configuration.url.path
        for file in [path, path + "-wal", path + "-shm"] {
          try? FileManager.default.removeItem(atPath: file)
        }
        return (try ModelContainer(for: schema, configurations: configuration), true)
      }
    }
  }
#endif

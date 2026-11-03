#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData
  import EventKit

  /// Takes back exactly what a card's Add wrote, and finds it again for Open. The card keeps the created item's id
  /// (`Ledger.ref` JSON) and the Activity entry of its creation (`StoredCard.itemRef` / `entryID`).
  @MainActor
  package enum CaptureUndo {
    package enum Item {
      case task(OneTask)
      case event(OneEvent)
      case alarm(OneAlarm)
    }

    package static func decode(_ ref: String) -> PersistentIdentifier? {
      ref.data(using: .utf8).flatMap {
        try? JSONDecoder().decode(PersistentIdentifier.self, from: $0)
      }
    }

    /// The item an Add wrote, or nil when it is gone (deleted since).
    package static func resolve(_ ref: String?, in context: ModelContext) -> Item? {
      guard let ref, let id = decode(ref) else { return nil }
      switch id.entityName {
      case "OneTask":
        var d = FetchDescriptor<OneTask>(predicate: #Predicate { $0.persistentModelID == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first.map(Item.task)
      case "OneEvent":
        var d = FetchDescriptor<OneEvent>(predicate: #Predicate { $0.persistentModelID == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first.map(Item.event)
      case "OneAlarm":
        var d = FetchDescriptor<OneAlarm>(predicate: #Predicate { $0.persistentModelID == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first.map(Item.alarm)
      default:
        return nil
      }
    }

    private static func entry(_ id: UUID?, in context: ModelContext, ledger: Ledger) -> LedgerItem?
    {
      guard let id else { return nil }
      // the creation may still be waiting to be written to the Activity store
      ledger.flush(context)
      guard let store = ledger.activity.store, let event = try? store.event(uid: id.uuidString)
      else { return nil }
      return LedgerItem(event: event)
    }

    /// Removes the created item and records the undo in Activity. An item that is already gone counts as taken back.
    /// False only when it could not be removed (an event in a read-only calendar).
    package static func undo(
      itemRef: String?, entryID: UUID?, title: String, context: ModelContext,
      calendar: any CalendarService, alarms: any AlarmService, ledger: Ledger
    ) -> Bool {
      let created = entry(entryID, in: context, ledger: ledger)
      switch resolve(itemRef, in: context) {
      case nil:
        return true
      case .task(let task):
        // The Activity undo of a creation: removes the reminder (and its Apple Reminders copy) and records "undone".
        if let created, ledger.undo(created, context: context) { return true }
        // A creation receipt can be missing when Changes recording is paused.
        // Deletion still uses the same injected reminder adapter through Ledger.
        return ledger.removeCreatedTask(task, context: context, channel: .ask)
      case .alarm(let alarm):
        context.delete(alarm)
        do { try context.save() } catch { return false }
        record(created, kind: "alarm", title: title, context: context, ledger: ledger)
        Task { await alarms.sync(context) }
        return true
      case .event(let event):
        guard calendar.delete(event, span: .thisEvent) else { return false }
        context.delete(event)
        do { try context.save() } catch { return false }
        record(created, kind: "event", title: title, context: context, ledger: ledger)
        return true
      }
    }

    private static func record(
      _ created: LedgerItem?, kind: String, title: String, context: ModelContext, ledger: Ledger
    ) {
      if let created {
        ledger.recordUndo(of: created, channel: .ask, context: context)
      } else {
        ledger.record(.deleted, kind: kind, title: title, channel: .ask, context: context)
      }
    }
  }

  /// A title-only edit never copies a stale Capture back over dates, recurrence or alarm state.
  extension CaptureUndo {
    package static func title(
      _ ref: String?, in context: ModelContext, calendar: any CalendarService
    ) -> String? {
      switch resolve(ref, in: context) {
      case .task(let task): return task.title
      case .alarm(let alarm): return alarm.label
      case .event(let event):
        if let externalID = event.externalID {
          return calendar.title(externalID: externalID, occurrence: event.start)
        }
        return event.title
      case nil: return nil
      }
    }

    /// Changes an added event's calendar and alert in place (the card's menu after Added). Undo still removes it.
    package static func setEventOptions(
      _ ref: String?, calendarID: String?, alertMinutes: Int?, in context: ModelContext,
      calendar: any CalendarService
    ) -> Bool {
      guard case .event(let event) = resolve(ref, in: context) else { return false }
      if let externalID = event.externalID {
        guard
          let id = calendar.setOptions(
            externalID: externalID, occurrence: event.start, calendarID: calendarID,
            alertMinutes: alertMinutes)
        else { return false }
        event.externalID = id
      }
      event.reminderOffsetMinutes = alertMinutes
      do { try context.save() } catch { return false }
      return true
    }

    /// Resolving again at commit time prevents a deleted item from being resurrected by an open sheet or Undo toast.
    @discardableResult
    package static func rename(
      _ ref: String?, to title: String, in context: ModelContext,
      calendar: any CalendarService, reminders: any ReminderService, alarms: any AlarmService
    ) -> Bool {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      switch resolve(ref, in: context) {
      case .alarm(let alarm):
        let old = alarm.label
        alarm.label = title
        do { try context.save() } catch {
          alarm.label = old
          return false
        }
        Task { await alarms.sync(context) }
      case .task(let task):
        let old = task.title
        task.title = title
        do { try context.save() } catch {
          task.title = old
          return false
        }
        reminders.scheduleReconcile()
      case .event(let event):
        let old = event.title
        // Local events stay local. For linked events, edit the existing EventKit object only:
        // the general save path also writes dates/repeats and can create a replacement.
        let externalID = event.externalID
        let oldLinkedTitle = externalID.flatMap {
          calendar.title(externalID: $0, occurrence: event.start)
        }
        if let externalID {
          guard oldLinkedTitle != nil,
            calendar.rename(externalID: externalID, occurrence: event.start, to: title)
          else { return false }
        }
        event.title = title
        do { try context.save() } catch {
          event.title = old
          // Best-effort compensating write, never pretend the two stores share a transaction.
          if let externalID, let oldLinkedTitle {
            _ = calendar.rename(externalID: externalID, occurrence: event.start, to: oldLinkedTitle)
          }
          return false
        }
      case nil: return false
      }
      return true
    }
  }
#endif

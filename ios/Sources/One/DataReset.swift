#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore
  import TodayShared
  /// Clears Today's own data. Never touches Apple Calendar or Apple Reminders.
  @MainActor
  package protocol ShareInboxReading {
    func read() throws -> [SharedReminder]
    func acknowledge(_ ids: Set<UUID>) -> Bool
  }

  @MainActor
  package enum DataReset {
    @discardableResult
    package static func run(
      _ context: ModelContext, reminders: any ReminderService, ledger: Ledger,
      inbox: any ShareInboxReading, focus: TodayFocus
    ) -> Bool {
      // Clear the independent overlay before any model deletion. A failed write keeps all local data.
      do { try focus.clear() } catch { return false }
      // Forget the link first so a local wipe is never mirrored to Apple Reminders.
      reminders.forgetLink()
      try? context.delete(model: OneTask.self)
      try? context.delete(model: OneEvent.self)
      try? context.delete(model: OneAlarm.self)
      try? context.delete(model: OneList.self)
      try? context.delete(model: ChatThread.self)
      // Clear pending shares before forgetting receipts, or an ack failure could resurrect deleted reminders.
      // If the inbox is unreadable, retain only the opaque receipts until it can be safely cleared.
      if let pending = try? inbox.read(),
        pending.isEmpty || inbox.acknowledge(Set(pending.map(\.id)))
      {
        try? context.delete(model: ShareImportReceipt.self)
      }
      ledger.clearAll()
      try? context.save()
      return true
    }
  }

#endif

#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore

  /// Updates retained notification/widget mirrors after a verified system move.
  /// The system receipt remains the write authority; this is not a second sync engine.
  @MainActor
  package final class CalendarMoveMirrors {
    private struct State: Equatable {
      let start: Date
      let externalID: String?
      let rule: String?
      let overrides: [OccurrenceTimeOverride]

      init(_ event: OneEvent) {
        start = event.start
        externalID = event.externalID
        rule = event.repeatRule
        overrides = event.occurrenceOverrides
      }

      init(before: State, receipt: CalendarMoveReceipt) {
        rule = before.rule
        if rule == nil {
          start = receipt.after.start
          externalID = receipt.after.externalID
          overrides = before.overrides
        } else {
          start = before.start
          externalID = before.externalID
          overrides = OccurrenceTimes.moving(
            before.overrides, from: receipt.before.start, to: receipt.after.start,
            externalID: receipt.after.externalID)
        }
      }

      init(restoring before: State, systemID: String?, occurrence: Date) {
        start = before.start
        externalID = before.rule == nil ? systemID ?? before.externalID : before.externalID
        rule = before.rule
        if before.rule != nil, let systemID, systemID != before.externalID {
          overrides = OccurrenceTimes.moving(
            before.overrides, from: occurrence, to: occurrence, externalID: systemID)
        } else {
          overrides = before.overrides
        }
      }

      func apply(to event: OneEvent) {
        event.start = start
        event.externalID = externalID
        event.occurrenceOverrides = overrides
      }
    }

    private let context: ModelContext
    private let rows: [(event: OneEvent, before: State)]
    private let occurrence: Date
    private var after: [State]?

    package init(expected: CalendarMoveSnapshot, context: ModelContext) throws {
      self.context = context
      occurrence = expected.start
      rows = try context.fetch(FetchDescriptor<OneEvent>()).filter {
        $0.externalID == expected.externalID
          || $0.occurrenceOverrides.contains(where: { $0.externalID == expected.externalID })
      }.map { ($0, State($0)) }
      try validate(rows.map(\.before))
      for row in rows {
        guard row.event.occurs(on: expected.start).contains(expected.start) else {
          throw CalendarMoveError.stale
        }
      }
    }

    package var isEmpty: Bool { rows.isEmpty }

    package static func isRestored(_ current: CalendarMoveSnapshot, before: CalendarMoveSnapshot)
      -> Bool
    {
      current.start == before.start && current.end == before.end
        && current.calendarID == before.calendarID && current.sourceID == before.sourceID
        && current.isAllDay == before.isAllDay && current.title == before.title
        && current.location == before.location && current.notes == before.notes
        && current.url == before.url && current.audience == before.audience
        && current.participantIDs == before.participantIDs
    }

    package func apply(_ receipt: CalendarMoveReceipt, save: (() throws -> Void)? = nil) throws {
      let target = rows.map { State(before: $0.before, receipt: receipt) }
      try write(from: rows.map(\.before), to: target, save: save)
      after = target
    }

    package func validateMoved() throws {
      guard let after else { throw CalendarMoveError.stale }
      try validate(after)
    }

    package func restore(systemID: String? = nil, save: (() throws -> Void)? = nil) throws {
      guard let after else { throw CalendarMoveError.stale }
      try write(
        from: after,
        to: rows.map { State(restoring: $0.before, systemID: systemID, occurrence: occurrence) },
        save: save)
    }

    private func validate(_ expected: [State]) throws {
      guard !rows.isEmpty else { return }
      let saved = try ModelContext(context.container).fetch(FetchDescriptor<OneEvent>())
      for (index, row) in rows.enumerated() {
        guard !row.event.isDeleted, row.event.modelContext === context,
          State(row.event) == expected[index],
          let persisted = saved.first(where: {
            $0.persistentModelID == row.event.persistentModelID
          }), State(persisted) == expected[index]
        else { throw CalendarMoveError.stale }
      }
    }

    private func write(from expected: [State], to target: [State], save: (() throws -> Void)?)
      throws
    {
      try validate(expected)
      guard !rows.isEmpty else { return }
      for (index, row) in rows.enumerated() { target[index].apply(to: row.event) }
      do {
        if let save { try save() } else { try context.save() }
      } catch {
        for (index, row) in rows.enumerated() { expected[index].apply(to: row.event) }
        throw error
      }
    }
  }
#endif

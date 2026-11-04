#if os(iOS)
  import Foundation
  import SwiftData
  import One
  import TodayCore
  import TodayData

  /// An ephemeral occurrence-specific preview; it is never a second persistent planner model.
  @MainActor
  final class TimelineMoveRequest {
    let timing: TimelineDragTime
    let attendees: Int
    private let perform: (Date) async throws -> (() -> Void)
    private var busy = false
    private var completed = false

    init(
      timing: TimelineDragTime, attendees: Int = 0,
      perform: @escaping (Date) async throws -> (() -> Void)
    ) {
      self.timing = timing
      self.attendees = attendees
      self.perform = perform
    }

    func apply(_ date: Date, toast: UndoToast?) async throws {
      guard !busy, !completed, date >= timing.earliest, date <= timing.latest else {
        throw CocoaError(.validationDateTooLate)
      }
      busy = true
      defer { busy = false }
      let undo = try await perform(date)
      completed = true
      toast?.show("Time changed", undo: undo)
    }
  }
#endif

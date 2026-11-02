#if os(iOS)
  import One
  import SwiftUI

  /// Imports display snapshots for saved Calendar Settle choices. It lives in a child so that Calendar changes
  /// (EventKit also posts them for every Reminders write) and Focus changes never re-run the whole shell.
  struct FocusHydrationObserver: View {
    let session: PlannerSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
      Color.clear
        .accessibilityHidden(true)
        .task(id: "\(session.calendar.version):\(session.actions.focus.revision):\(scenePhase)") {
          guard scenePhase == .active else { return }
          await session.calendar.hydrateFocus(session.actions.focus.records)
        }
    }
  }
#endif

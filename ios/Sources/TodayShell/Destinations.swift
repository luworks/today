#if os(iOS)
  import SwiftUI
  import SwiftData
  import One
  import TodayCore
  import TodayPlatform
  import FeatureCalendar
  import FeatureReminders
  import FeatureClock
  import FeatureSettings
  import FeatureActivity
  import FeatureAsk

  /// Editors stay over the current modal root; dismissing restores its original navigation state.
  package struct PlannerEditor: View {
    let destination: OpenedEntry
    let toast: UndoToast
    let composition: ShellComposition
    private var session: PlannerSession { composition.session }
    @ViewBuilder package var body: some View {
      switch destination {
      case .task(let task):
        TaskEditor(
          task: task, actions: session.actions, ledger: session.ledger,
          reminders: session.reminders,
          alarms: session.alarms, presentation: composition.presentation)
      case .local(let event):
        eventEditor(event: event)
      case .alarm(let alarm):
        AlarmEditor(
          alarm: alarm, alarms: session.alarms, soundPreview: session.soundPreview,
          runtime: session.runtime, defaults: session.defaults,
          onCreated: composition.recordCreatedAlarm)
      case .system(let identifier), .editSystem(let identifier):
        if let native = session.calendar as? any NativeCalendarService {
          NativeEventSheet(identifier: identifier, start: session.runtime.now(), calendar: native)
        } else {
          ContentUnavailableView(
            "Calendar unavailable", systemImage: "calendar.badge.exclamationmark")
        }
      case .new(let start, let end):
        EventEditor(
          start: start, end: end, calendar: session.calendar, actions: session.actions,
          ledger: session.ledger, alarms: session.alarms, presentation: composition.presentation)
      }
    }
    private func eventEditor(event: OneEvent) -> some View {
      EventEditor(
        event: event, calendar: session.calendar, actions: session.actions,
        ledger: session.ledger, alarms: session.alarms, presentation: composition.presentation)
    }
  }

  package struct ShellSettings: View {
    @Environment(UndoToast.self) private var toast: UndoToast?
    @Environment(\.modelContext) private var context
    let diagnostics: LocalDiagnostics
    let composition: ShellComposition
    var selection: SettingsView.Selection = .all
    private var session: PlannerSession { composition.session }
    package var body: some View {
      SettingsView(
        selection: selection, calendar: session.calendar, reminders: session.reminders,
        notifications: session.notifications, alarms: session.alarms, ledger: session.ledger,
        openSettings: composition.openSettings, rewriteWidgets: session.widget.rewriteFromStore,
        diagnostics: diagnostics,
        exportDiagnostics: {
          let url = FileManager.default.temporaryDirectory.appending(
            path: "TodayDiagnostics", directoryHint: .isDirectory
          )
          .appending(path: "diagnostics-\(session.runtime.nextID().uuidString).json")
          return try diagnostics.exportURL(to: url)
        },
        calendars: { AnyView(CalendarsSheet(calendar: session.calendar)) },
        holidays: { AnyView(YearHolidaysSettingsView(presentation: composition.presentation)) },
        activityData: {
          AnyView(
            ActivityDataView(
              activity: session.activity,
              exportDestination: { format in
                let directory = FileManager.default.temporaryDirectory.appending(
                  path: "ActivityExports", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                  at: directory, withIntermediateDirectories: true)
                return directory.appending(
                  path:
                    "activity-\(session.runtime.nextID().uuidString).\(format == .csv ? "csv" : "jsonl")"
                )
              }, summary: { session.activity.summary() },
              clear: { session.activity.clear(context: context) },
              export: { try await session.activity.export($0, to: $1) },
              legacyRowCount: { (try? context.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0 }))
        },
        shareDiagnostics: { AnyView(SystemFileSheet(url: $0)) },
        reset: {
          if !DataReset.run(
            $0, reminders: session.reminders, ledger: session.ledger, inbox: session.inbox,
            focus: session.actions.focus)
          {
            toast?.showNotice(
              "Couldn't clear saved Focus choices. Your local data was kept. Try again.")
          }
        }, wheelLab: wheelLab)
    }

    private var wheelLab: (@MainActor () -> AnyView)? {
      #if DEBUG
        let runtime = session.runtime
        return { AnyView(AlarmWheelLab(runtime: runtime)) }
      #else
        return nil
      #endif
    }
  }

  package struct AskScreen: View {
    let thread: ChatThread?
    var subject: AskSubject? = nil
    let toast: UndoToast
    let composition: ShellComposition
    let isPresented: Bool
    let onClose: () -> Void
    let onMenu: () -> Void
    let onBack: (Bool) -> Void
    let onAdded: (Capture) -> Void
    let onOpenDay: (Date) -> Void
    @State private var editor: OpenedEntry?
    @State private var didDismissEditor: (() -> Void)?
    private var session: PlannerSession { composition.session }
    package var body: some View {
      AskView(
        thread: thread, subject: subject, isPresented: isPresented, onClose: onClose,
        onMenu: onMenu,
        calendar: session.calendar, now: session.runtime.now,
        actions: session.actions, ledger: session.ledger, activity: session.activity,
        intelligence: composition.intelligence, agentModel: composition.agentModel,
        voice: composition.voice,
        presentation: composition.presentation,
        travel: session.travel, suggestionMemory: composition.suggestionMemory,
        onBack: onBack, onAdded: onAdded, onOpenDay: onOpenDay,
        onOpenTask: { task, completion in
          didDismissEditor = completion
          editor = .task(task)
        },
        onOpenAlarm: { alarm, completion in
          didDismissEditor = completion
          editor = .alarm(alarm)
        }
      )
      .sheet(
        item: $editor,
        onDismiss: {
          let completion = didDismissEditor
          didDismissEditor = nil
          completion?()
        }
      ) { PlannerEditor(destination: $0, toast: toast, composition: composition) }
    }
  }

  private struct SystemFileSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
  }
#endif

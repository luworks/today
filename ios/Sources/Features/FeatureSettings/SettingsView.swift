#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import FeatureHealth
  import One
  import SwiftUI
  import SwiftData
  import UserNotifications
  import UIKit

  /// Settings is its own screen (opened from the sidebar). Each screen's options live here, not in the sidebar;
  /// the destructive "Delete All Data" is the last row and needs two confirmations.
  package struct SettingsView: View {
    /// SceneCatalog selects the same production sections rather than recreating their controls.
    package enum Selection: Equatable {
      case all, appearance, apple, today, calendar, reminders, smartLists, alarms, holidays, ai,
        activity, about, data
    }

    private let selection: Selection
    private let calendar: any CalendarService
    private let reminders: any ReminderService
    private let notifications: any NotificationService
    private let alarms: any AlarmService
    private let ledger: Ledger
    private let openSettings: @MainActor () -> Void
    private let rewriteWidgets: @MainActor () -> Void
    private let diagnostics: LocalDiagnostics
    private let calendars: @MainActor () -> AnyView
    private let holidays: @MainActor () -> AnyView
    private let activityData: @MainActor () -> AnyView
    private let exportDiagnostics: @MainActor () throws -> URL
    private let shareDiagnostics: @MainActor (URL) -> AnyView
    private let reset: @MainActor (ModelContext) -> Void
    /// Debug builds only: the alarm wheel lab (Developer section).
    private let wheelLab: (@MainActor () -> AnyView)?

    package init(
      selection: Selection = .all,
      calendar: any CalendarService, reminders: any ReminderService,
      notifications: any NotificationService,
      alarms: any AlarmService, ledger: Ledger,
      openSettings: @escaping @MainActor () -> Void,
      rewriteWidgets: @escaping @MainActor () -> Void,
      diagnostics: LocalDiagnostics,
      exportDiagnostics: @escaping @MainActor () throws -> URL,
      calendars: @escaping @MainActor () -> AnyView,
      holidays: @escaping @MainActor () -> AnyView,
      activityData: @escaping @MainActor () -> AnyView,
      shareDiagnostics: @escaping @MainActor (URL) -> AnyView,
      reset: @escaping @MainActor (ModelContext) -> Void,
      wheelLab: (@MainActor () -> AnyView)? = nil
    ) {
      self.alarms = alarms
      self.ledger = ledger
      self.openSettings = openSettings
      self.rewriteWidgets = rewriteWidgets
      self.selection = selection
      self.calendar = calendar
      self.reminders = reminders
      self.notifications = notifications
      self.diagnostics = diagnostics
      self.exportDiagnostics = exportDiagnostics
      self.calendars = calendars
      self.holidays = holidays
      self.activityData = activityData
      self.shareDiagnostics = shareDiagnostics
      self.reset = reset
      self.wheelLab = wheelLab
      _calendarOn = State(initialValue: calendar.isOn)
      _remindersOn = State(initialValue: reminders.isConnected)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(WeatherModel.self) private var weather
    @Environment(\.modelContext) private var context

    @AppStorage(Appearance.storageKey) private var appearance = Appearance.default.rawValue
    @AppStorage(SettingsKey.showAlarms) private var showAlarms = true
    @AppStorage(SettingsKey.jumpToNow) private var jumpToNow = true
    @AppStorage(SettingsKey.autoArchiveChats) private var autoArchiveChats = true
    @AppStorage(SmartListLayout.orderKey) private var smartOrder = ""
    @AppStorage(SmartListLayout.hiddenKey) private var smartHidden = ""
    @AppStorage(SettingsKey.travelTime) private var travelTime = true
    @AppStorage(SettingsKey.healthSummary) private var healthSummary = true
    @AppStorage(Preferences.weatherSummaryKey) private var weatherSummary = Preferences
      .weatherSummary

    @State private var systemColorScheme: ColorScheme = .light
    @State private var systemAppearanceObservation: (UIWindowScene, any UITraitChangeRegistration)?
    @State private var calendarOn: Bool
    @State private var remindersOn: Bool
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showsCalendars = false
    @State private var diagnosticExport: DiagnosticExport?
    @State private var diagnosticExportFailed = false
    @State private var askingFirst = false
    @State private var askingSecond = false
    @AppStorage(ActivitySettings.pausedKey) private var activityPaused = false

    package var body: some View {
      NavigationStack {
        Form {
          if includes(.appearance) { appearanceSection }
          if includes(.apple) { appleSection }
          if includes(.today) { todaySection }
          if includes(.calendar) { CalendarSettingsSection() }
          if includes(.reminders) { RemindersSettingsSection() }
          if includes(.smartLists) { smartListsSection }
          if includes(.alarms) { AlarmsSettingsSection() }
          if includes(.holidays) { holidaysSection }
          if includes(.ai) { aiSection }
          if includes(.activity) { activitySection }
          #if DEBUG
            if selection == .all, let wheelLab { developerSection(wheelLab) }
          #endif
          if includes(.about) { aboutSection }
          if includes(.data) { dataSection }
        }
        .performanceDestination("settings")
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
          ledger.flush(context)
          notificationStatus = await notifications.authorizationStatus()
        }
        .onChange(of: calendarOn) { _, on in
          guard on != calendar.isOn else { return }
          Task {
            await calendar.setEnabled(on)
            calendarOn = calendar.isOn  // stays off if access was refused
          }
        }
        .onChange(of: travelTime) { _, _ in
          rewriteWidgets()  // add or drop "Leave by" on the widget
        }
        .onChange(of: remindersOn) { _, on in
          guard on != reminders.isConnected else { return }
          Task {
            if on { await reminders.connect() } else { reminders.disconnect() }
            remindersOn = reminders.isConnected
          }
        }
        .confirmationDialog(
          "Delete all data stored in Today?", isPresented: $askingFirst, titleVisibility: .visible
        ) {
          Button("Continue…", role: .destructive) { askingSecond = true }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "This deletes the reminders, events, alarms, lists and Activity Today keeps on this device. It can't be undone."
          )
        }
        .sheet(isPresented: $showsCalendars) {
          calendars().performanceDestination("settings.calendars")
        }
        .sheet(item: $diagnosticExport) { export in
          shareDiagnostics(export.url)
        }
        .alert("Couldn’t export diagnostics", isPresented: $diagnosticExportFailed) {
          Button("OK", role: .cancel) {}
        } message: {
          Text("Please try again.")
        }
        .sheet(isPresented: $askingSecond) {
          DeleteDataConfirmation {
            reset(context)
            dismiss()
          }
        }
      }
      // Update the open sheet without retaining a presentation-level override when returning to System.
      .environment(\.colorScheme, Appearance(stored: appearance).colorScheme ?? systemColorScheme)
      .onAppear {
        guard
          let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first
        else { return }
        systemColorScheme = scene.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
          (scene: UIWindowScene, _: UITraitCollection) in
          systemColorScheme = scene.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        systemAppearanceObservation = (scene, registration)
      }
      .onDisappear {
        if let (scene, registration) = systemAppearanceObservation {
          scene.unregisterForTraitChanges(registration)
          systemAppearanceObservation = nil
        }
      }
    }

    private func includes(_ section: Selection) -> Bool {
      selection == .all || selection == section
    }

    private var appearanceSection: some View {
      Section {
        AppearanceSettingsRow()
        TodayButtonColorRow()
      }
    }

    private var appleSection: some View {
      Section {
        Toggle(isOn: $calendarOn) { Label("Apple Calendar", systemImage: "calendar") }
        Toggle(isOn: $remindersOn) { Label("Apple Reminders", systemImage: "checklist") }
        Button {
          PerformanceTrace.shared.beginPage("settings.calendars")
          showsCalendars = true
        } label: {
          HStack {
            Label("Calendars", systemImage: "calendar.badge.checkmark")
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(
              .tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose which calendars show in Today")
        statusRow(
          title: "Alarms", icon: "alarm",
          value: alarms.isAvailable
            ? (alarms.authorization == .denied ? "Not allowed" : "Allowed") : "Needs iOS 26",
          showsSettings: alarms.authorization == .denied)
        statusRow(
          title: "Notifications", icon: "bell.badge",
          value: notificationStatus == .authorized || notificationStatus == .provisional
            ? "Allowed"
            : (notificationStatus == .denied ? "Not allowed" : "Off"),
          showsSettings: notificationStatus == .denied,
          turnOn: notificationStatus == .notDetermined
            ? {
              Task {
                _ = await notifications.requestPermission()
                notificationStatus = await notifications.authorizationStatus()
              }
            } : nil)
      } header: {
        Text("Apple Calendar, Reminders and Alarms")
      } footer: {
        Text(
          "Today shows your Apple Calendar events and Apple Reminders next to your alarms. Your data stays in Apple's apps; Today does not send it anywhere."
        )
      }
    }

    private var todaySection: some View {
      Section {
        Toggle("Show alarms in Today and Calendar", isOn: $showAlarms)
        Toggle("Scroll to now when Today opens", isOn: $jumpToNow)
        TodayTimelineSettings()
        explainedToggle(
          "Travel time", isOn: $travelTime,
          caption:
            "Shows the drive time and when to leave for events with a location today and tomorrow. Your location and the event's address go to Apple Maps only; nothing else leaves your iPhone."
        )
        explainedToggle(
          "Health summary", isOn: $healthSummary,
          caption:
            "Shows one line from Apple Health on Today: your steps and last night's sleep, or the first metrics you chose. Today only reads them."
        )
        HealthMetricsLink()
        OpenHealthButton()
        if weather.isAvailable {
          explainedToggle(
            "Weather summary", isOn: $weatherSummary,
            caption:
              "Shows current weather and an hourly forecast on Today. When enabled, your location is sent to Apple Weather to obtain the forecast."
          )
        }
      } header: {
        Text("Today")
      }
    }

    private var holidaysSection: some View {
      Section {
        NavigationLink {
          holidays().performanceDestination("settings.holidays")
        } label: {
          Label("Holidays in Year", systemImage: "flag")
        }
        .performanceControlledNavigation("settings.holidays") {
          holidays().performanceDestination("settings.holidays")
        } label: {
          Label("Holidays in Year", systemImage: "flag")
        }
        .accessibilityIdentifier("settings.yearHolidays")
      } header: {
        Text("Calendar")
      } footer: {
        Text("Which holidays and festivals the Year view marks.")
      }
    }

    private var aiSection: some View {
      Section {
        NavigationLink("Luna AI") { AIAccountView() }
        AskSuggestionsSettingRow()
        explainedToggle(
          "Archive finished chats", isOn: $autoArchiveChats,
          caption:
            "A chat moves to Archived a week after its last message, or an hour after everything it added is done. Archived chats stay in the sidebar under Archived."
        )
      } header: {
        Text("AI")
      }
    }

    private var activitySection: some View {
      Section {
        NavigationLink {
          activityData()
        } label: {
          HStack {
            Label("Activity data", systemImage: "clock.arrow.circlepath")
            Spacer()
            Text(activityPaused ? "Paused" : "On").foregroundStyle(.secondary)
          }
        }
        .performanceControlledNavigation("settings.activityData") {
          activityData()
        } label: {
          HStack {
            Label("Activity data", systemImage: "clock.arrow.circlepath")
            Spacer()
            Text(activityPaused ? "Paused" : "On").foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("settings.activityData")
      } header: {
        Text("Activity")
      } footer: {
        Text(
          "Today keeps a record of changes and AI decisions, only on this iPhone. See what is recorded, pause it, export it or clear it."
        )
      }
    }

    #if DEBUG
      private func developerSection(_ wheelLab: @escaping @MainActor () -> AnyView) -> some View {
        Section {
          NavigationLink {
            wheelLab()
          } label: {
            Label("Alarm wheel lab", systemImage: "dial.medium")
          }
          .accessibilityIdentifier("settings.wheelLab")
        } header: {
          Text("Developer")
        } footer: {
          Text("Debug builds only. Compares alarm time pickers; never creates an alarm.")
        }
      }
    #endif

    private var aboutSection: some View {
      Section {
        LabeledContent("Version", value: Self.version)
        Button("Export diagnostics") {
          do {
            diagnosticExport = DiagnosticExport(url: try exportDiagnostics())
          } catch {
            diagnosticExportFailed = true
          }
        }
        .accessibilityIdentifier("settings.exportDiagnostics")
      } header: {
        Text("About")
      }
    }

    private var dataSection: some View {
      // Last, on purpose: nothing destructive sits anywhere else in the app.
      Section {
        Button(role: .destructive) {
          askingFirst = true
        } label: {
          Text("Delete All Data…")
        }
      } header: {
        Text("Data")
      } footer: {
        Text(
          "Clears what Today stores on this device. Your Apple Calendar and Apple Reminders are not changed."
        )
      }
    }

    /// Which smart lists show at the top of Reminders: a switch per list, press, hold and drag to reorder (no Edit mode).
    private var smartListsSection: some View {
      let layout = SmartListLayout(order: smartOrder, hidden: smartHidden)
      return Section {
        ForEach(layout.order) { smart in
          Toggle(
            isOn: Binding(
              get: { !layout.hidden.contains(smart) },
              set: { shown in
                var l = SmartListLayout(order: smartOrder, hidden: smartHidden)
                if shown { l.hidden.remove(smart) } else { l.hidden.insert(smart) }
                smartHidden = l.hiddenString
              }
            )
          ) {
            HStack(spacing: 12) {
              ListGlyph(color: smart.color, symbol: smart.symbol, size: 28)
              Text(smart.title)
            }
          }
          .accessibilityIdentifier("smartToggle.\(smart.rawValue)")
        }
        .onMove { from, to in
          var l = SmartListLayout(order: smartOrder, hidden: smartHidden)
          l.order.move(fromOffsets: from, toOffset: to)
          smartOrder = l.orderString
        }
      } header: {
        Text("Reminders Smart Lists")
      } footer: {
        Text("Shown at the top of Reminders. Press and hold one, then drag, to change the order.")
      }
    }

    /// A switch with its own short explanation right under it (a Section footer can only describe the whole group).
    private func explainedToggle(_ title: String, isOn: Binding<Bool>, caption: String) -> some View
    {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(title, isOn: isOn)
        Text(caption)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 2)
    }

    private func statusRow(
      title: String, icon: String, value: String, showsSettings: Bool, turnOn: (() -> Void)? = nil
    ) -> some View {
      HStack {
        Label(title, systemImage: icon)
        Spacer()
        if let turnOn {
          Button("Turn On", action: turnOn).font(.subheadline)
        } else if showsSettings {
          Button("Open Settings") {
            openSettings()
          }
          .font(.subheadline)
        } else {
          Text(value).foregroundStyle(.secondary)
        }
      }
    }

    private struct DiagnosticExport: Identifiable {
      let id = UUID()
      let url: URL
    }

    private static var version: String {
      let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
      let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
      return "\(v) (\(b))"
    }
  }

  /// Second confirmation: the user must type DELETE before the button works.
  package struct DeleteDataConfirmation: View {
    package init(onConfirm: @escaping () -> Void) { self.onConfirm = onConfirm }
    @Environment(\.dismiss) private var dismiss
    var onConfirm: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    package var body: some View {
      NavigationStack {
        Form {
          Section {
            Text(
              "Everything Today stores on this device will be deleted: reminders, events, alarms and lists. Apple Calendar and Apple Reminders are not touched."
            )
            TextField("Type DELETE to confirm", text: $typed)
              .textInputAutocapitalization(.characters)
              .autocorrectionDisabled()
              .focused($focused)
          }
          Section {
            Button("Delete All Data", role: .destructive) {
              onConfirm()
              dismiss()
            }
            .disabled(typed.trimmingCharacters(in: .whitespaces).uppercased() != "DELETE")
          }
        }
        .navigationTitle("Are you sure?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { focused = true }
      }
      .presentationDetents([.medium])
    }
  }

#endif

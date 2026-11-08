#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  /// Settings > Today > Customize Up Next: how much the Lock Screen card shows. Every change recomputes the card at once.
  struct UpNextSettingsView: View {
    let changed: @MainActor (String, String) -> Void

    @AppStorage(Preferences.upNextWindowHoursKey) private var windowHours =
      Preferences.upNextWindowHours
    @AppStorage(Preferences.upNextMaxItemsKey) private var maxItems = Preferences.upNextMaxItems
    @AppStorage(Preferences.upNextEventsKey) private var events = Preferences.upNextEvents
    @AppStorage(Preferences.upNextRemindersKey) private var reminders = Preferences.upNextReminders
    @AppStorage(Preferences.upNextAlarmsKey) private var alarms = Preferences.upNextAlarms

    var body: some View {
      Form {
        Section {
          PillChoiceRow(
            title: "Time window", items: Preferences.upNextWindowHourChoices,
            selection: $windowHours, caption: "Shows items starting within this time.",
            label: { "\($0) h" }, identifier: { "settings.upNextWindow.\($0)" })
          PillChoiceRow(
            title: "Maximum items", items: Preferences.upNextMaxItemChoices,
            selection: $maxItems, caption: nil,
            label: { "\($0)" }, identifier: { "settings.upNextMaxItems.\($0)" })
        }
        Section {
          Toggle("Events", isOn: $events)
          Toggle("Reminders", isOn: $reminders)
          Toggle("Alarms", isOn: $alarms)
        } header: {
          Text("Show")
        } footer: {
          Text("With all three off, no card appears.")
        }
      }
      .navigationTitle("Up Next")
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: windowHours) { _, hours in
        changed(Preferences.upNextWindowHoursKey, String(hours))
      }
      .onChange(of: maxItems) { _, count in changed(Preferences.upNextMaxItemsKey, String(count)) }
      .onChange(of: events) { _, on in changed(Preferences.upNextEventsKey, on ? "1" : "0") }
      .onChange(of: reminders) { _, on in changed(Preferences.upNextRemindersKey, on ? "1" : "0") }
      .onChange(of: alarms) { _, on in changed(Preferences.upNextAlarmsKey, on ? "1" : "0") }
    }
  }
#endif

#if os(iOS)
  import SwiftUI
  import os
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform

  /// Visibility and global order are edited as one draft; permission requests wait for dismissal.
  public struct HealthMetricPicker: View {
    @Binding private var selection: HealthSelection
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var customizing = false

    public init(selection: Binding<HealthSelection>) { self._selection = selection }

    /// Compatibility for existing development scenes that only edit visibility.
    public init(shown: Binding<Set<HealthMetric>>) {
      self._selection = Binding(
        get: {
          HealthSelection(shown: HealthMetric.allCases.filter { shown.wrappedValue.contains($0) })
        },
        set: { shown.wrappedValue = Set($0.shown) })
    }

    private func matches(_ metric: HealthMetric) -> Bool {
      search.isEmpty
        || "\(metric.title) \(metric.group.title)".localizedCaseInsensitiveContains(search)
    }

    public var body: some View {
      NavigationStack {
        List {
          Section {
            ForEach(selection.shown.filter(matches)) { metric in metricRow(metric) }
              .onMove { from, to in
                Logger(subsystem: "com.luworks.today", category: "health.reorder")
                  .debug(
                    "Picker move from \(from.description, privacy: .public) to \(to, privacy: .public)"
                  )
                selection.move(from: from, to: to)
              }
              .moveDisabled(!search.isEmpty)
          } header: {
            Text("Shown · Your Order")
          } footer: {
            Text(
              "Drag across categories in Customize. Only the metrics you choose request read access."
            )
          }
          ForEach(HealthGroup.allCases, id: \.self) { group in
            let hidden = selection.hidden.filter { $0.group == group && matches($0) }
            if !hidden.isEmpty {
              Section(group.title) {
                ForEach(hidden) { metric in metricRow(metric).moveDisabled(true) }
              }
            }
          }
          Section {
            OpenHealthButton()
          } footer: {
            // Health never tells an app that reading was denied, so this covers both "no data" and "not allowed".
            Text(
              "Today only reads Apple Health; nothing leaves your iPhone. \"No data\" can also mean Today isn't allowed to read it: check Health → Profile → Apps → Today."
            )
          }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search Metrics")
        .environment(\.editMode, .constant(customizing ? .active : .inactive))
        .performanceDestination("health.picker")
        .navigationTitle("Health Metrics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(customizing ? "Finish" : "Customize") { customizing.toggle() }
              .disabled(!search.isEmpty)
              .accessibilityLabel(customizing ? "Done Customizing" : "Customize")
              .accessibilityIdentifier("health.pick.customize")
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.accessibilityIdentifier("health.pick.add")
          }
        }
      }
      .presentationDragIndicator(.visible)
    }

    private func metricRow(_ metric: HealthMetric) -> some View {
      Toggle(
        isOn: Binding(
          get: { selection.shown.contains(metric) },
          set: { if $0 { selection.add([metric]) } else { selection.hide(metric) } }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text(metric.title).font(.body)
          Text(metric.summary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("health.pick.row.\(metric.rawValue)")
      }
      .tint(HealthStyle.accent)
      .frame(minHeight: 52)
      .accessibilityIdentifier("health.pick.\(metric.rawValue)")
    }
  }
#endif

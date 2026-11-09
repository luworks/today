#if os(iOS)
  import One
  import TodayData
  import TodayPlatform
  import SwiftUI

  /// Settings → Activity → Activity data: what Today records about your use, where it lives, and the basics: pause, switch a
  /// category off, how long changes are kept, export (JSON Lines or CSV) and clear. Everything stays on this iPhone.
  @MainActor
  package struct ActivityDataView: View {
    @AppStorage(ActivitySettings.pausedKey) private var paused = false
    @AppStorage(ActivitySettings.retentionKey) private var retentionRaw = ActivityRetention.default
      .rawValue
    @AppStorage(ActivitySettings.keepChatTextKey) private var keepChatText = true
    @AppStorage(ActivitySettings.tierKey(.changes)) private var keepChanges = true
    @AppStorage(ActivitySettings.tierKey(.ai)) private var keepAI = true
    @AppStorage(ActivitySettings.tierKey(.usage)) private var keepUsage = true
    @AppStorage(ActivitySettings.tierKey(.system)) private var keepSystem = true

    @State private var summary = ActivityCenter.Summary()
    @State private var askingClear = false
    @State private var exporting = false
    @State private var exported: ExportedFile?
    @State private var exportFailed = false
    @State private var benchmark: String?
    @State private var benchmarking = false

    private let activity: ActivityCenter
    private let exportDestination: @MainActor (ActivityExportFormat) throws -> URL
    private let readSummary: @MainActor () -> ActivityCenter.Summary
    private let clear: @MainActor () -> Void
    private let exportFile: @MainActor (ActivityExportFormat, URL) async throws -> URL

    package init(
      activity: ActivityCenter,
      exportDestination: @escaping @MainActor (ActivityExportFormat) throws -> URL,
      summary: @escaping @MainActor () -> ActivityCenter.Summary,
      clear: @escaping @MainActor () -> Void,
      export: @escaping @MainActor (ActivityExportFormat, URL) async throws -> URL
    ) {
      self.activity = activity
      self.exportDestination = exportDestination
      self.readSummary = summary
      self.clear = clear
      self.exportFile = export
    }

    private struct ExportedFile: Identifiable {
      let id = UUID()
      let url: URL
    }

    private var retention: Binding<ActivityRetention> {
      Binding(
        get: { ActivityRetention(rawValue: retentionRaw) ?? .default },
        set: { retentionRaw = $0.rawValue })
    }

    package var body: some View {
      Form {
        Section {
          Toggle("Pause recording", isOn: $paused)
            .accessibilityIdentifier("activity.pause")
        } footer: {
          Text(
            "While paused nothing new is recorded, in any category. What is already recorded stays until you clear it."
          )
        }

        Section {
          tierToggle(.changes, $keepChanges)
          tierToggle(.ai, $keepAI)
          tierToggle(.usage, $keepUsage)
          tierToggle(.system, $keepSystem)
          Toggle(isOn: $keepChatText) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Keep the text of my messages")
              Text(
                "On: the text of your messages to the AI is stored on this iPhone with the rest of your activity. Off: only its length and language are recorded."
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("activity.keepChatText")
        } header: {
          Text("What is recorded 5")
        } footer: {
          Text(
            ActivityNote.neverRecorded
              + " While Changes is off (or recording is paused), “Always for 7 days” does not apply anything by itself, because there would be no Activity entry or Undo for it."
          )
        }

        Section {
          LabeledContent("Stored") { Text("On this iPhone").foregroundStyle(.secondary) }
          ForEach(ActivityTier.allCases) { tier in
            LabeledContent(tier.title) {
              Text("\(summary.perTier[tier] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
            }
          }
          LabeledContent("Size") {
            Text(ByteCountFormatter.string(fromByteCount: summary.fileBytes, countStyle: .file))
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Where it lives")
        } footer: {
          Text(
            ActivityNote.whereStored
              + " Export it below if you want a copy; deleting the app deletes it.")
        }
        .accessibilityIdentifier("activity.where")

        Section {
          Picker("Keep activity for", selection: retention) {
            ForEach(ActivityRetention.allCases) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("activity.retention")
        } footer: {
          Text(
            "Forever keeps raw activity in all categories. With a shorter choice, changes follow that period; AI decisions are kept 180 days, usage 30 days and system events 90 days. Undo snapshots are kept 30 days."
          )
        }

        Section {
          ForEach(ActivityExportFormat.allCases) { format in
            Button {
              export(format)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text("Export \(format.rawValue)…")
                Text(format.summary).font(.footnote).foregroundStyle(.secondary)
              }
            }
            .disabled(exporting || summary.total == 0)
            .accessibilityIdentifier("activity.export.\(format.fileExtension)")
          }
        } header: {
          Text("Export")
        } footer: {
          Text(
            exportFailed
              ? "The export did not work. Try again."
              : "Opens the share sheet, so you can save the file to Files, send it by AirDrop or mail it."
          )
        }

        Section {
          Button(role: .destructive) {
            askingClear = true
          } label: {
            Text("Clear activity history…")
          }
          .disabled(summary.total == 0)
          .accessibilityIdentifier("activity.clear")
        } footer: {
          Text(
            "Deletes everything recorded here. Your reminders, events and alarms stay as they are, and so do Apple Calendar and Apple Reminders."
          )
        }

        #if DEBUG
          Section {
            Button(benchmarking ? "Running…" : "Run speed test (100,000 rows)") { runBenchmark() }
              .disabled(benchmarking)
              .accessibilityIdentifier("activity.benchmark")
            if let benchmark { Text(benchmark).font(.caption.monospaced()).textSelection(.enabled) }
          } header: {
            Text("Debug")
          } footer: {
            Text(
              "Inserts rows into a throwaway database file, times the queries, and deletes it. Your data is not touched."
            )
          }
        #endif
      }
      .performanceDestination("settings.activityData")
      .navigationTitle("Activity data")
      .navigationBarTitleDisplayMode(.inline)
      .task { refresh() }
      .onReceive(NotificationCenter.default.publisher(for: activity.didChange, object: activity)) {
        _ in refresh()
      }
      .confirmationDialog(
        "Clear activity history?", isPresented: $askingClear, titleVisibility: .visible
      ) {
        Button("Clear \(summary.total) Events", role: .destructive) {
          clear()
          refresh()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "The record of past changes, AI decisions, usage and system events is deleted from this iPhone. Undo from Activity stops working for what is cleared."
        )
      }
      .sheet(item: $exported) { file in
        ActivityFileSheet(url: file.url).presentationDetents([.medium, .large])
      }
    }

    private func tierToggle(_ tier: ActivityTier, _ isOn: Binding<Bool>) -> some View {
      Toggle(isOn: isOn) {
        VStack(alignment: .leading, spacing: 2) {
          Text(tier.title)
          Text(tier.detail).font(.footnote).foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("activity.tier.\(tier.rawValue)")
    }

    private func refresh() {
      summary = readSummary()
    }

    private func export(_ format: ActivityExportFormat) {
      exporting = true
      exportFailed = false
      Task {
        do {
          exported = ExportedFile(url: try await exportFile(format, exportDestination(format)))
        } catch { exportFailed = true }
        exporting = false
      }
    }

    #if DEBUG
      private func runBenchmark() {
        benchmarking = true
        benchmark = nil
        Task.detached(priority: .utility) {
          let text = (try? ActivityBenchmark.run(rows: 100_000).summary) ?? "The speed test failed."
          await MainActor.run {
            benchmark = text
            benchmarking = false
          }
        }
      }
    #endif
  }

#endif

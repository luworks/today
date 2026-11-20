#if os(iOS)
  import One
  import TodayCore
  import SwiftUI
  import SwiftData

  struct FreeTimeChoice: Identifiable {
    let id = UUID()
    let gap: DateInterval
  }

  struct FreeTimeSheet: View {
    struct Row: Identifiable {
      let task: OneTask
      let detail: String
      var id: PersistentIdentifier { task.persistentModelID }
    }

    let title: String
    let subtitle: String
    let rows: [Row]
    let footer: String
    let place: (OneTask) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        List {
          Section {
            if rows.isEmpty {
              Text("No open reminder fits here.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
              Button {
                dismiss()
                place(row.task)
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(row.task.title).foregroundStyle(.primary)
                  Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("freeTime.candidate")
              .accessibilityHint("Makes it due at the start of this free time. Undo is offered.")
            }
          } header: {
            Text(subtitle)
          } footer: {
            Text(footer)
          }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .accessibilityIdentifier("freeTime.sheet")
    }
  }
#endif

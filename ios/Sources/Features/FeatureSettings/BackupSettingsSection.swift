#if os(iOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import One

  package struct BackupSettingsSection: View {
    @State private var picker = false
    @State private var confirm = false
    private var backup: BackupController { .shared }
    package var body: some View {
      Section {
        Button(backup.folder.isEmpty ? "Choose Backup Folder…" : "Change Backup Folder…") {
          picker = true
        }
        if !backup.folder.isEmpty { Text("Folder: \(backup.folder)") }
        if let date = backup.lastSaved { LabeledContent("Last saved", value: date.formatted()) }
        Text(backup.status).font(.footnote).accessibilityIdentifier("backup.status")
        if backup.hasRemote {
          Button("Restore on Next Launch…") { confirm = true }
          Text(
            "Keep both by leaving restore unselected. Automatic backup stays paused when the folder has an unacknowledged backup."
          ).font(.footnote)
        }
        Button("Retry Backup") { backup.retry() }
      } header: {
        Text("Backup & Restore")
      } footer: {
        Text(
          "Choose iCloud Drive/Today or another folder once for automatic backups. Files manages cloud synchronization; a local save does not confirm an upload. After reinstalling, choose the same folder here to find your backup. Restore replaces Today’s local view on the next launch; the old store is retained. Restored alarms stay off until reviewed."
        )
      }
      .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { backup.select(url) }
      }
      .confirmationDialog(
        "Replace Today’s local data on next launch?", isPresented: $confirm,
        titleVisibility: .visible
      ) {
        Button("Prepare Restore", role: .destructive) { backup.stageRestore() }
        Button("Keep Local Data and Backup", role: .cancel) {}
      } message: {
        Text(
          "Reminders, chats, history and backed-up settings will be replaced in Today. The original local store is retained. Apple Calendar and Reminders are reconciled; restored alarms require review."
        )
      }
      .onDisappear { backup.schedule() }
    }
  }
#endif

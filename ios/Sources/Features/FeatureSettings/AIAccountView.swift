#if os(iOS)
  import SwiftUI
  import TodayPlatform

  struct AIAccountView: View {
    @State private var account = AIAccount.shared
    @State private var username = ""
    @State private var password = ""
    @State private var register = false
    @State private var consent = false
    @State private var deleting = false

    var body: some View {
      Form {
        Section {
          Text("GPT-6 Luna")
          Text(
            "AI requests send your message and limited relevant chat or planner context to Today AI and OpenAI. Your full calendar, reminders and Health databases stay on your iPhone."
          )
          .font(.footnote).foregroundStyle(.secondary)
        } header: {
          Text("Luna AI")
        }
        if let name = account.username {
          Section {
            LabeledContent("Signed in as", value: name)
            Toggle("Use cloud AI", isOn: $account.enabled)
            if let used = account.used, let limit = account.dailyLimit {
              LabeledContent("AI requests today (UTC)", value: "\(used) / \(limit)")
            }
            Button("Sign out") { Task { await account.signOut() } }
              .disabled(account.busy)
            Button("Delete AI account", role: .destructive) { deleting = true }
              .disabled(account.busy)
          } footer: {
            Text(
              "A message may use more than one AI call. Limits protect shared service costs. Signing out leaves your planner and chats on this iPhone."
            )
          }
        } else {
          Section {
            Picker("Account", selection: $register) {
              Text("Sign in").tag(false)
              Text("Create account").tag(true)
            }.pickerStyle(.segmented)
            TextField("Username", text: $username)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .textContentType(.username)
            SecureField("Password (12 or more characters)", text: $password)
              .textContentType(register ? .newPassword : .password)
            Toggle("Allow the AI requests described above", isOn: $consent)
            Button(register ? "Create AI account" : "Sign in to AI") {
              Task {
                await account.authenticate(
                  username: username, password: password, register: register)
                if account.username != nil { password = "" }
              }
            }.disabled(account.busy || !consent || username.count < 3 || password.count < 12)
          } footer: {
            Text(
              "Use 3–48 letters, numbers, dots, underscores or hyphens for your username. Keep your password: password recovery is not available yet. Accounts are currently limited to the initial rollout."
            )
          }
        }
        if account.busy { ProgressView() }
        if let error = account.error {
          Section {
            Text(error).foregroundStyle(.secondary).accessibilityIdentifier("ai-account-error")
          }
        }
      }
      .navigationTitle("Luna AI")
      .task { await account.refresh() }
      .confirmationDialog(
        "Delete your AI account?", isPresented: $deleting, titleVisibility: .visible
      ) {
        Button("Delete AI account", role: .destructive) {
          Task { await account.signOut(deleteAccount: true) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This removes your AI login and sessions. Your planner data and chats on this iPhone are kept."
        )
      }
    }
  }
#endif

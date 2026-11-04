import QuietInboxCore
import SwiftUI
import UIKit

@main
struct QuietInboxApp: App {
    var body: some Scene {
        WindowGroup { InboxHome() }
    }
}

@MainActor
final class PolicyStore: ObservableObject {
    @Published var policy = FilterPolicy()
    @Published var error: String?
    private var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luworks.quietinbox")?
            .appendingPathComponent("policy.json")
    }

    init() {
        guard let file else {
            error = "Shared rules are unavailable. Check App Group signing before using the filter."
            return
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { policy = try JSONDecoder().decode(FilterPolicy.self, from: Data(contentsOf: file)) }
        catch { self.error = "Saved rules could not be read. Save your rules again before relying on them." }
    }

    func save() {
        do {
            guard let file else { throw CocoaError(.fileNoSuchFile) }
            try JSONEncoder().encode(policy).write(to: file, options: .atomic)
            error = nil
        } catch { self.error = "Rules could not be saved. The filter may still use your previous rules." }
    }
}

struct InboxHome: View {
    @StateObject private var store = PolicyStore()
    @State private var sender = ""
    @State private var bodyText = ""
    @State private var result: FilterDecision?
    @State private var newSender = ""
    @State private var allowSender = false
    private let engine = FilterEngine()

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 42)).foregroundStyle(.teal)
                            Text("A quieter inbox.").font(.largeTitle.bold())
                            Text("Private, on-device filtering for new messages from unknown senders.")
                                .foregroundStyle(.secondary)
                            Label("Experimental preview", systemImage: "flask")
                                .font(.caption.bold()).foregroundStyle(.orange)
                        }.padding(.vertical, 12)
                    }
                    Section("Set up in Messages") {
                        Text("Open Settings → Apps → Messages → Unknown & Spam, then select Quiet Inbox. Names may vary by iOS version.")
                        Text("System activation: not verified").foregroundStyle(.secondary)
                        Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        Text("This opens this app’s settings. Navigate to Messages to choose the filter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Filtering preferences") {
                        Toggle("Use filtering rules", isOn: $store.policy.enabled)
                            .onChange(of: store.policy.enabled) { _, _ in store.save() }
                        Text("This preference does not enable the system extension. Turn it off to return no filtering decision for future messages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    Section("What to expect") {
                        Label("Messages stays your inbox", systemImage: "message")
                        Text("iOS handles Junk and delivery. Quiet Inbox cannot read your message history, delete messages, or restore previously filtered messages.")
                        Text("iMessage and known senders are outside this filter. RCS behavior needs verification on your iPhone.")
                        Text("The small synthetic training set is a prototype, not validated protection. Uncertain messages receive no filtering decision.")
                    }
                }.navigationTitle("Quiet Inbox")
            }.tabItem { Label("Protection", systemImage: "shield") }
            NavigationStack {
                Form {
                    Section {
                        Text("Test a message privately. Nothing is sent or saved, and this does not change Messages.")
                            .foregroundStyle(.secondary)
                        TextField("Sender (optional)", text: $sender).textInputAutocapitalization(.never)
                        TextEditor(text: $bodyText).frame(minHeight: 150)
                            .accessibilityLabel("Message to analyze")
                        Button("Analyze on this iPhone") {
                            result = engine.classify(sender: sender, body: bodyText, policy: store.policy)
                        }.disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let result {
                        Section("Preview decision") {
                            Label(title(result.action), systemImage: result.action == .junk ? "tray" : "info.circle")
                                .font(.headline)
                            Text(result.reason)
                            Text("A preview does not prove the system extension is enabled or predict thread-level behavior.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Try a synthetic example") {
                        Button("Suspicious prize") { bodyText = "Congratulations! Claim your free cash prize now. Click the link to collect your reward."; result = nil }
                        Button("Verification code") { bodyText = "Your verification code is 482913. Do not share this code with anyone."; result = nil }
                    }
                }.navigationTitle("Message Lab")
                    .onChange(of: bodyText) { _, _ in result = nil }
                    .onChange(of: sender) { _, _ in result = nil }
            }.tabItem { Label("Message Lab", systemImage: "text.magnifyingglass") }
            NavigationStack {
                List {
                    Section("Add an exact sender") {
                        TextField("Phone number or sender ID", text: $newSender).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Always allow this sender", isOn: $allowSender)
                        Button(allowSender ? "Add to allowed senders" : "Add to blocked senders") {
                            let value = newSender.trimmingCharacters(in: .whitespacesAndNewlines)
                            if allowSender {
                                if !store.policy.allowedSenders.contains(value) { store.policy.allowedSenders.append(value) }
                            } else if !store.policy.blockedSenders.contains(value) { store.policy.blockedSenders.append(value) }
                            store.save()
                            newSender = ""
                            result = nil
                        }.disabled(newSender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Allowed senders take priority. Country codes are significant. Rules affect future eligible messages only; they do not change Apple’s blocked contacts list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    senderSection("Allowed senders", values: store.policy.allowedSenders, allowed: true)
                    senderSection("Blocked senders", values: store.policy.blockedSenders, allowed: false)
                    if let error = store.error { Section { Text(error).foregroundStyle(.orange) } }
                }.navigationTitle("Sender Rules")
            }.tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }
        }.tint(.teal)
    }

    private func title(_ action: FilterAction) -> String {
        switch action {
        case .allow: "Allow"
        case .junk: "Suggest Junk"
        case .review: "No filtering decision"
        }
    }

    private func senderSection(_ title: String, values: [String], allowed: Bool) -> some View {
        Section(title) {
            if values.isEmpty { Text("No senders added").foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text(value) }
                .onDelete { offsets in
                    if allowed { store.policy.allowedSenders.remove(atOffsets: offsets) }
                    else { store.policy.blockedSenders.remove(atOffsets: offsets) }
                    store.save()
                    result = nil
                }
        }
    }
}

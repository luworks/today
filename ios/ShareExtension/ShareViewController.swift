import SwiftUI
import TodayShared
import UIKit
import UniformTypeIdentifiers

/// The Share sheet's "Today" action: what was shared (text, or a page from Safari) becomes a reminder you can edit, with an
/// optional day. Nothing is added until you tap Add. The reminder goes into the App Group inbox (`ShareInbox`); the app adds
/// it the next time it is active (and syncs it to Apple Reminders when that is on).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    Task { @MainActor [weak self] in
      guard let self else { return }
      let input = await loadInput()
      let draft = ShareInbox.draft(text: input.text, url: input.url, pageTitle: input.pageTitle)
      let sheet = ShareSheet(
        title: draft.title, note: draft.note,
        onCancel: { [weak self] in self?.finish(added: false) },
        onAdd: { [weak self] reminder in
          ShareInbox.submit(reminder) {
            // Never the SQLite file: a small JSONL file in the App Group outbox (imported by the app).
            ActivityOutbox.append(
              kind: "sys.share.add", actor: "share", channel: "share",
              props: ["has_note": !reminder.note.isEmpty, "has_due": reminder.due != nil])
            self?.finish(added: true)
          }
        })
      let host = UIHostingController(rootView: sheet)
      addChild(host)
      host.view.frame = view.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(host.view)
      host.didMove(toParent: self)
    }
  }

  private func finish(added: Bool) {
    if added {
      extensionContext?.completeRequest(returningItems: nil)
    } else {
      extensionContext?.cancelRequest(
        withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
  }

  private func readURL(_ provider: NSItemProvider) async -> URL? {
    if provider.canLoadObject(ofClass: NSURL.self) {
      let url: URL? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSURL.self) { value, _ in
          continuation.resume(returning: value as? URL)
        }
      }
      if let url { return url }
    }
    return await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
        continuation.resume(
          returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
      }
    }
  }

  private func readText(_ provider: NSItemProvider) async -> String? {
    if provider.canLoadObject(ofClass: NSString.self) {
      let text: String? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
          continuation.resume(returning: value as? String)
        }
      }
      if let text { return text }
    }
    return await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) {
        data, _ in
        continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
      }
    }
  }

  /// The first text, link and page title among the shared items.
  private func loadInput() async -> (text: String?, url: URL?, pageTitle: String?) {
    var text: String?
    var url: URL?
    var pageTitle: String?
    for item in extensionContext?.inputItems.compactMap({ $0 as? NSExtensionItem }) ?? [] {
      if pageTitle == nil, let t = item.attributedContentText?.string, !t.isEmpty { pageTitle = t }
      for provider in item.attachments ?? [] {
        if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
          let value = await readURL(provider)
        {
          url = value
        } else if text == nil,
          provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
          let value = await readText(provider)
        {
          text = value
        }
      }
    }
    // Text that is just a link counts as the link.
    if url == nil, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      let u = URL(string: t), u.scheme?.hasPrefix("http") == true
    {
      url = u
    }
    // Safari passes the page title as the item's text; it is not a note.
    if text == pageTitle { text = nil }
    return (text, url, pageTitle)
  }
}

/// New Reminder, the way Apple's own share sheets look: Cancel, a title, Add; the title and note are editable, and a day is optional.
struct ShareSheet: View {
  @State var title: String
  @State var note: String
  var onCancel: () -> Void
  var onAdd: (SharedReminder) -> Bool
  @State private var day: ShareInbox.Day = .none
  @State private var saveFailed = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title, axis: .vertical)
            .lineLimit(1...4)
          TextField("Notes", text: $note, axis: .vertical)
            .lineLimit(1...4)
            .foregroundStyle(.secondary)
        }
        Section {
          Picker("Date", selection: $day) {
            ForEach(ShareInbox.Day.allCases) { Text($0.rawValue).tag($0) }
          }
        } footer: {
          Text("Adds a reminder to Today. It appears the next time you open the app.")
        }
        if saveFailed {
          Section {
            Text("Couldn't save the reminder. Your text is still here. Try Add again, or cancel.")
              .foregroundStyle(.red)
              .accessibilityIdentifier("share.saveError")
          }
        }
      }
      .navigationTitle("New Reminder")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            saveFailed = !onAdd(
              SharedReminder(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                due: ShareInbox.due(for: day)))
          }
          .fontWeight(.semibold)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}

private let ciTrialShare = 1

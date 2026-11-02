#if os(iOS)
  import SwiftUI
  import TodayCore

  /// AI preview: what will be created. The user can switch reminder / event / alarm before tapping Add.
  package struct CaptureCard: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    package init(
      capture: Binding<Capture>, lists: [String] = [], status: CardStatus = .open,
      onAdd: @escaping () -> Void, onCancel: @escaping () -> Void, cancelTitle: String = "Cancel",
      onUndo: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {},
      onRename: @escaping (String) -> Bool = { _ in false }
    ) {
      _capture = capture
      self.lists = lists
      self.status = status
      self.onAdd = onAdd
      self.onCancel = onCancel
      self.cancelTitle = cancelTitle
      self.onUndo = onUndo
      self.onOpen = onOpen
      self.onRename = onRename
    }
    @Binding package var capture: Capture
    /// The user's Reminders lists; when given, a task shows which one it goes to, changeable with one tap.
    package var lists: [String] = []
    /// Open until the user decides. The card stays in the conversation afterwards (see `CardFooter`).
    package var status: CardStatus = .open
    package var onAdd: () -> Void
    package var onCancel: () -> Void
    package var cancelTitle = "Cancel"
    package var onUndo: () -> Void = {}
    package var onOpen: () -> Void = {}

    package var onRename: (String) -> Bool = { _ in false }

    package enum Mode: Hashable, CaseIterable { case task, event, alarm }

    /// An alarm is a task that rings; it needs a time, so switching to Alarm with none picks the next full hour.
    private var mode: Binding<Mode> {
      Binding(
        get: { capture.kind == .event ? .event : (capture.ringsAsAlarm ? .alarm : .task) },
        set: { new in
          switch new {
          case .task:
            capture.kind = .task
            capture.ringsAsAlarm = false
          case .event:
            capture.kind = .event
            capture.ringsAsAlarm = false
          case .alarm:
            capture.kind = .task
            capture.ringsAsAlarm = true
            capture.isAllDay = false
            if capture.hour == nil {
              let next =
                presentation.calendar.date(byAdding: .hour, value: 1, to: presentation.now)
                ?? presentation.now
              let c = presentation.calendar.dateComponents([.hour], from: next)
              capture.hour = c.hour ?? 9
              capture.minute = 0
              if !presentation.calendar.isDate(next, inSameDayAs: presentation.now) {
                capture.day = presentation.calendar.startOfDay(for: next)
                capture.hasDay = true
              }
            }
          }
        })
    }

    package var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(capture.kindLabel, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        if status == .open {
          PillSwitcher(
            items: Mode.allCases, selection: mode,
            title: { kind in
              switch kind {
              case .task: "Reminder"
              case .event: "Event"
              case .alarm: "Alarm"
              }
            },
            identifier: { "capture.kind." + String(describing: $0) })
        }
        CaptureTitleButton(
          title: capture.title, editable: status == .open || status == .added,
          onSave: { title in
            if status == .open {
              capture.title = title
              return true
            }
            return onRename(title)
          }
        ).font(.headline)
        Text(
          capture.summary(
            now: presentation.now, calendar: presentation.calendar, locale: presentation.locale)
        ).font(.subheadline).foregroundStyle(.secondary)
        if let notes = capture.notes, !notes.isEmpty {
          Text(notes).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier(
            "capture-notes")
        }
        if capture.kind == .task, !capture.ringsAsAlarm {
          if status == .open {
            if !lists.isEmpty { ListMenu(capture: $capture, lists: lists).font(.subheadline) }
          } else {
            Label(capture.listLabel, systemImage: "list.bullet").font(.subheadline).foregroundStyle(
              .secondary
            ).lineLimit(1)
          }
        }
        if status == .open {
          HStack {
            Button(cancelTitle, action: onCancel).buttonStyle(.bordered)
            Spacer()
            Button(action: onAdd) {
              Text("Add").foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
            }.buttonStyle(.borderedProminent).disabled(
              !capture.isReadyToAdd(calendar: presentation.calendar))
          }
          .padding(.top, 4)
        } else {
          CardFooter(status: status, onAdd: onAdd, onUndo: onUndo, onOpen: onOpen)
            .padding(.top, 4)
        }
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
      .opacity(status == .dropped ? 0.55 : 1)
      .modifier(DecidedCardLabel(status: status, capture: capture))
    }
  }

  /// A decided card reads as one thing to VoiceOver ("Added: Call Alex, Tomorrow 15:00 · alerts you") with its buttons inside.
  private struct DecidedCardLabel: ViewModifier {
    @Environment(PlannerPresentation.self) private var presentation
    let status: CardStatus
    let capture: Capture

    func body(content: Content) -> some View {
      if status == .open {
        content
      } else {
        content
          .accessibilityElement(children: .contain)
          .accessibilityLabel(
            status.accessibilityLabel(
              for: capture, now: presentation.now, calendar: presentation.calendar,
              locale: presentation.locale))
      }
    }
  }

  package struct CaptureTitleButton: View {
    package init(title: String, editable: Bool = true, onSave: @escaping (String) -> Bool) {
      self.title = title
      self.editable = editable
      self.onSave = onSave
    }
    package let title: String
    package var editable = true
    package var onSave: (String) -> Bool
    @State private var editing = false

    package var body: some View {
      Group {
        if editable {
          Button {
            editing = true
          } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Change title")
          .accessibilityIdentifier("capture-title")
        } else {
          Text(title)
        }
      }
      .sheet(isPresented: $editing) { CaptureTitleEditor(title: title, onSave: onSave) }
    }
  }

  private struct CaptureTitleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var failed = false
    @FocusState private var focused: Bool
    let onSave: (String) -> Bool

    init(title: String, onSave: @escaping (String) -> Bool) {
      _title = State(initialValue: title)
      self.onSave = onSave
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
      NavigationStack {
        Form {
          TextField("Title", text: $title, axis: .vertical)
            .focused($focused)
            .accessibilityIdentifier("capture-title-field")
          if failed {
            Text("Couldn't save this title. The item may have been deleted.").foregroundStyle(
              .secondary)
          }
        }
        .navigationTitle("Title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.accessibilityIdentifier("capture-title-cancel")
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              if onSave(trimmed) { dismiss() } else { failed = true }
            }
            .disabled(trimmed.isEmpty)
            .accessibilityIdentifier("capture-title-save")
          }
        }
        .task { focused = true }
      }
    }
  }
  /// The bottom line of a card once it is decided: a green check "Added" with Undo and Open, "Undone" with Add again, or a
  /// quiet "Dropped" with nothing to tap. The same on the full card and on a row of a list.
  package struct CardFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    package init(
      status: CardStatus, compact: Bool = false, onAdd: @escaping () -> Void = {},
      onUndo: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {}
    ) {
      self.status = status
      self.compact = compact
      self.onAdd = onAdd
      self.onUndo = onUndo
      self.onOpen = onOpen
    }
    package let status: CardStatus
    package var compact = false
    package var onAdd: () -> Void = {}
    package var onUndo: () -> Void = {}
    package var onOpen: () -> Void = {}

    private var font: Font { compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold) }

    package var body: some View {
      HStack(spacing: 8) {
        switch status {
        case .open:
          EmptyView()
        case .added:
          Label("Added", systemImage: "checkmark.circle.fill")
            .font(font)
            .foregroundStyle(.green)
            .symbolEffect(.bounce, value: status)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture-added")
          Spacer(minLength: 8)
          small("Undo", id: "capture-undo", action: onUndo)
          small("Open", id: "capture-open", action: onOpen)
        case .undone:
          Label("Undone", systemImage: "arrow.uturn.backward.circle")
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture-undone")
          Spacer(minLength: 8)
          Button(action: onAdd) {
            Text("Add again")
              .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .controlSize(.small)
          .accessibilityIdentifier("capture-add-again")
        case .dropped:
          Label("Dropped", systemImage: "xmark.circle")
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture-dropped")
          Spacer(minLength: 0)
        }
      }
    }

    private func small(_ title: String, id: String, action: @escaping () -> Void) -> some View {
      Button(title, action: action)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier(id)
    }
  }

  /// Where a task will be filed. One tap opens the user's lists.
  package struct ListMenu: View {
    package init(capture: Binding<Capture>, lists: [String]) {
      _capture = capture
      self.lists = lists
    }
    @Binding package var capture: Capture
    package let lists: [String]

    package var body: some View {
      Menu {
        Picker(
          "List",
          selection: Binding(
            get: { capture.listName == "Reminders" ? "" : capture.listName ?? "" },
            set: { capture.listName = $0.isEmpty ? nil : $0 })
        ) {
          // The list with no name of its own is Apple's "Reminders" (`listName == ""`).
          Text("Reminders").tag("")
          ForEach(lists.filter { !$0.isEmpty && $0 != "Reminders" }, id: \.self) {
            Text($0).tag($0)
          }
        }
      } label: {
        Label(capture.listLabel, systemImage: "list.bullet")
          .lineLimit(1)
      }
      .tint(.secondary)
      .accessibilityLabel("List: \(capture.listLabel)")
      .accessibilityIdentifier("capture-list")
    }
  }

#endif

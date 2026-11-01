#if os(iOS)
  import TodayCore
  import TodayDesignSystem
  import SwiftUI

  /// One item the AI proposes from the user's line. Nothing is written until it is added. The card stays in the
  /// conversation afterwards: Added (with Undo and Open), Dropped, or Undone (with Add again).
  package struct CaptureProposal: Identifiable, Equatable {
    package var id = UUID()
    package var capture: Capture
    /// The proposal as the AI first made it, to tell what the user changed before Add (Activity data, edited-card diffs).
    package let original: Capture
    package var status: CardStatus = .open
    /// How many items the line produced; a line with several keeps the list layout.
    package var batchSize = 1
    /// The items of one line share a batch.
    package var batch = UUID()
    /// The AI message the card sits under.
    package var anchor: UUID?
    /// What Add wrote (the created item's id and its Activity entry), kept so Undo and Open reach exactly that.
    package var itemRef: String?
    package var entryID: UUID?
    package var retainsDraft = false
    package var pendingExternalID: String?
    /// The agent proposal id ("p1") when the agent prepared this card; nil for FastLane and the old pipeline.
    package var agentID: String?

    package init(capture: Capture, batchSize: Int = 1, batch: UUID = UUID(), anchor: UUID? = nil) {
      self.capture = capture
      self.original = capture
      self.batchSize = batchSize
      self.batch = batch
      self.anchor = anchor
    }

    package init(_ stored: StoredCard) {
      id = stored.id
      capture = stored.capture
      original = stored.capture
      status = stored.status
      batchSize = stored.batchSize
      batch = stored.batch
      anchor = stored.anchor
      itemRef = stored.itemRef
      entryID = stored.entryID
      retainsDraft = stored.retainsDraft
      pendingExternalID = stored.pendingExternalID
    }

    /// The saved form; nil for a card with no message to sit under.
    package var stored: StoredCard? {
      anchor.map {
        StoredCard(
          id: id, anchor: $0, batch: batch, batchSize: batchSize, capture: capture, status: status,
          itemRef: itemRef, entryID: entryID, retainsDraft: retainsDraft,
          pendingExternalID: pendingExternalID)
      }
    }
  }

  /// Every item from one line at once: a single item is the full preview card; several are compact rows with their own
  /// Add and Skip, one "Add all", and a tap to open a row for editing. Added items keep their place with a check, Undo and Open.
  package struct CaptureStack: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Binding package var proposals: [CaptureProposal]
    /// The user's Reminders lists, for the list menu on tasks.
    package let lists: [String]
    package var onAdd: (UUID) -> Void
    package var onSkip: (UUID) -> Void
    package var onAddAll: () -> Void
    package var onUndo: (UUID) -> Void
    package var onOpen: (UUID) -> Void

    package var onRename: (UUID, String) -> Bool

    package init(
      proposals: Binding<[CaptureProposal]>, lists: [String], onAdd: @escaping (UUID) -> Void,
      onSkip: @escaping (UUID) -> Void, onAddAll: @escaping () -> Void,
      onUndo: @escaping (UUID) -> Void, onOpen: @escaping (UUID) -> Void,
      onRename: @escaping (UUID, String) -> Bool
    ) {
      _proposals = proposals
      self.lists = lists
      self.onAdd = onAdd
      self.onSkip = onSkip
      self.onAddAll = onAddAll
      self.onUndo = onUndo
      self.onOpen = onOpen
      self.onRename = onRename
    }

    @State private var expanded: UUID?

    private var openCount: Int { proposals.filter { $0.status == .open }.count }
    private var addedCount: Int { proposals.filter { $0.status == .added }.count }

    package var body: some View {
      Group {
        if proposals.count == 1, let only = proposals.first, only.batchSize == 1 {
          CaptureCard(
            capture: binding(only.id), lists: lists, status: only.status,
            onAdd: { onAdd(only.id) }, onCancel: { onSkip(only.id) },
            onUndo: { onUndo(only.id) }, onOpen: { onOpen(only.id) },
            onRename: { onRename(only.id, $0) })
        } else {
          list
        }
      }
      .sensoryFeedback(.success, trigger: addedCount) { old, new in new > old }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("capture-stack")
    }

    private var headerTitle: String {
      if openCount > 0 { return "\(openCount) new item\(openCount == 1 ? "" : "s")" }
      if addedCount > 0 { return "Added" }
      return proposals.contains { $0.status == .undone } ? "Undone" : "Dropped"
    }

    private var list: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(headerTitle, systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if openCount > 1 {
            Button(action: onAddAll) {
              Text("Add all")
                .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
            }
            .disabled(
              !proposals.contains {
                $0.status == .open && $0.capture.isReadyToAdd(calendar: presentation.calendar)
              }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("capture-add-all")
          }
        }
        VStack(spacing: 8) {
          ForEach(proposals) { p in row(p) }
        }
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
    }

    @ViewBuilder
    private func row(_ p: CaptureProposal) -> some View {
      if p.status == .open, expanded == p.id {
        CaptureCard(
          capture: binding(p.id), lists: lists,
          onAdd: { onAdd(p.id) }, onCancel: { onSkip(p.id) }, cancelTitle: "Skip",
          onUndo: { onUndo(p.id) }, onOpen: { onOpen(p.id) },
          onRename: { onRename(p.id, $0) })
      } else {
        CompactCaptureRow(
          capture: binding(p.id), lists: lists, status: p.status,
          onOpen: { withAnimation(.snappy) { expanded = p.id } },
          onAdd: { onAdd(p.id) }, onSkip: { onSkip(p.id) },
          onUndo: { onUndo(p.id) }, onShow: { onOpen(p.id) },
          onRename: { onRename(p.id, $0) })
      }
    }

    private func binding(_ id: UUID) -> Binding<Capture> {
      Binding(
        get: {
          proposals.first { $0.id == id }?.capture
            ?? Capture(title: "", day: presentation.now, hasDay: false)
        },
        set: { new in
          if let i = proposals.firstIndex(where: { $0.id == id }),
            proposals[i].pendingExternalID == nil
          {
            proposals[i].capture = new
          }
        })
    }
  }

  /// A proposed item in a list of several: title, when, list, and its own Skip and Add. Tap the text to edit it.
  /// Once decided it keeps its place with the state it ended in (see `CardFooter`).
  struct CompactCaptureRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Binding var capture: Capture
    let lists: [String]
    var status: CardStatus = .open
    var onOpen: () -> Void
    var onAdd: () -> Void
    var onSkip: () -> Void
    var onUndo: () -> Void
    var onShow: () -> Void
    var onRename: (String) -> Bool

    var body: some View {
      if status == .open { openRow } else { decidedRow }
    }

    private var openRow: some View {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(capture.title).font(.subheadline.weight(.semibold)).lineLimit(2)
          Text(
            capture.summary(
              now: presentation.now, calendar: presentation.calendar, locale: presentation.locale)
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if capture.kind == .task, !capture.ringsAsAlarm, !lists.isEmpty {
            ListMenu(capture: $capture, lists: lists).font(.caption)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Edit")
        Button(action: onSkip) {
          Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(
            width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.secondary)
        .accessibilityLabel("Skip")
        Button(action: onAdd) {
          Image(systemName: "plus").font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add")
        .accessibilityIdentifier("capture-row-add")
        .disabled(!capture.isReadyToAdd(calendar: presentation.calendar))
      }
      .padding(10)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var decidedRow: some View {
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          CaptureTitleButton(title: capture.title, editable: status == .added, onSave: onRename)
            .font(.subheadline.weight(.semibold))
          Text(
            capture.summary(
              now: presentation.now, calendar: presentation.calendar, locale: presentation.locale)
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if capture.kind == .task, !capture.ringsAsAlarm {
            Label(capture.listLabel, systemImage: "list.bullet").font(.caption).foregroundStyle(
              .secondary
            ).lineLimit(1)
          }
        }
        .opacity(status == .dropped ? 0.55 : 1)
        CardFooter(status: status, compact: true, onAdd: onAdd, onUndo: onUndo, onOpen: onShow)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        status.accessibilityLabel(
          for: capture, now: presentation.now, calendar: presentation.calendar,
          locale: presentation.locale))
    }
  }

#endif

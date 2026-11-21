#if os(iOS)
  import One
  import TodayPlannerUI
  import TodayCore
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// Where a row or pill in Reminders leads. Lists are referenced by id so a rename or delete can't leave a stale model behind.
  package enum ReminderTarget: Hashable {
    case smart(SmartList)
    case list(PersistentIdentifier)
    /// Reminders that belong to no list (`listName == ""`); Apple calls this list "Reminders".
    case defaultList
  }

  /// The Reminders tab: small pills above the List (smart lists, then pinned lists), My Lists, Add List. Everything
  /// else is pushed inside this stack.
  /// No Edit button and no edit mode: editing works as everywhere else in the app. Press and hold a list for Rename,
  /// Color & Icon, Pin and Delete; press, hold and drag a row to reorder; swipe a row from the right for Delete, Info
  /// and Pin (`RowAction`). Which smart lists show, and in what order, is in Settings (or Hide in a pill's menu).
  package struct RemindersView: View {
    @Environment(PlannerPresentation.self) private var presentation
    /// True while a list screen is pushed, so the shell can leave the left-edge swipe to "back".
    @Binding var isPushed: Bool

    @Environment(\.modelContext) private var context
    @Query(sort: \OneList.order) private var lists: [OneList]
    @Query private var tasks: [OneTask]

    @AppStorage(SmartListLayout.orderKey) private var smartOrder = ""
    @AppStorage(SmartListLayout.hiddenKey) private var smartHidden = ""
    /// False until the user first drags My Lists; until then numbered lists ("01 工作") sort by their number.
    @AppStorage("reminders.listsReordered") private var listsReordered = false

    /// Which list is open. Kept by `HomeView`, so switching tabs and back returns to the same list.
    @Binding var path: [ReminderTarget]
    @State private var addingList = false
    @State private var editing: OneList?
    @State private var pendingDelete: PendingListDeletion?
    @State private var renaming: OneList?
    @State private var renameText = ""
    /// A pill is being dragged (its token), the pill it hovers over, and a counter that fires the drop haptic.
    @State private var dragging: String?
    @State private var dropTarget: String?
    @State private var reorderTick = 0

    private let sync: any ReminderService
    private let actions: PlannerActions
    private let ledger: Ledger
    private let alarms: any AlarmService
    private let openSettings: @MainActor () -> Void
    private let requestAccess: @MainActor () async -> Void

    package init(
      isPushed: Binding<Bool>, path: Binding<[ReminderTarget]>,
      sync: any ReminderService, actions: PlannerActions, ledger: Ledger, alarms: any AlarmService,
      presentation: PlannerPresentation, openSettings: @escaping @MainActor () -> Void,
      requestAccess: @escaping @MainActor () async -> Void
    ) {
      _isPushed = isPushed
      _path = path
      self.actions = actions
      self.ledger = ledger
      self.alarms = alarms
      self.openSettings = openSettings
      _smartOrder = AppStorage(
        wrappedValue: "", SmartListLayout.orderKey, store: presentation.defaults)
      _smartHidden = AppStorage(
        wrappedValue: "", SmartListLayout.hiddenKey, store: presentation.defaults)
      _listsReordered = AppStorage(
        wrappedValue: false, "reminders.listsReordered", store: presentation.defaults)
      self.sync = sync
      self.requestAccess = requestAccess
    }

    /// My Lists in display order: the user's own order once they have dragged, else numbered lists first by number.
    private var sortedLists: [OneList] {
      let lists = self.lists.filter { !$0.isDeleted }
      guard !listsReordered else { return lists }
      return lists.enumerated().sorted { a, b in
        let na = ListName.number(a.element.name)
        let nb = ListName.number(b.element.name)
        switch (na, nb) {
        case (let x?, let y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.offset < b.offset
        }
      }.map(\.element)
    }
    private var layout: SmartListLayout { SmartListLayout(order: smartOrder, hidden: smartHidden) }

    package var body: some View {
      let stats = Stats(
        tasks: tasks.filter { !$0.isDeleted }, now: presentation.now,
        calendar: presentation.calendar)
      NavigationStack(path: $path) {
        VStack(spacing: 0) {
          pills(stats)
          List {
            myLists(stats)
            if showsAccessOff {
              Section {
                Button {
                  openSettings()
                } label: {
                  Label(
                    "Apple Reminders is off for Today. Open Settings",
                    systemImage: "exclamationmark.circle"
                  )
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
              }
              .listSectionSeparator(.hidden)
            }
          }
          .listStyle(.plain)
          .environment(\.defaultMinListRowHeight, 0)
          .scrollContentBackground(.hidden)
          .background(Color(.systemBackground))
          // No empty band: My Lists sits right under the pills.
          .contentMargins(.top, 4, for: .scrollContent)
          // Room to scroll the last row clear of the app's floating bottom bar (search, Ask AI, +): the bar's
          // safe-area inset doesn't reach this list through the NavigationStack, so the rows ran under it.
          .contentMargins(.bottom, 96, for: .scrollContent)
          // Never in edit mode, and saying so explicitly matters: without a pinned-inactive edit mode, deleting a
          // list while the default "Reminders" row appears in the same update crashed UICollectionView (invalid
          // number of items in section), seen when a swipe deleted a list and kept its reminders.
          .environment(\.editMode, .constant(.inactive))
        }
        .background(Color(.systemBackground))
        // This is the title the pushed screen's back button shows.
        .navigationTitle("Lists")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ReminderTarget.self) {
          ReminderListScreen(
            target: $0, actions: actions, ledger: ledger, reminders: sync, alarms: alarms)
        }
      }
      // Apple's Reminders is blue whatever the app's accent is.
      .tint(Color(.systemBlue))
      .sheet(isPresented: $addingList) { ListEditor(ledger: ledger, reminders: sync) }
      .sheet(item: $editing) { ListEditor(list: $0, ledger: ledger, reminders: sync) }
      .deleteListAlert($pendingDelete, reminders: sync, ledger: ledger)
      // The same Rename as a conversation's in the sidebar. `presenting:` hands the list to the buttons: the alert
      // clears `renaming` as it closes, which can happen before Save's action runs.
      .alert(
        "Rename List",
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
        presenting: renaming
      ) { list in
        TextField("List Name", text: $renameText)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
          guard !list.isDeleted else { return }
          withAnimation(.snappy) {
            _ = ListActions.rename(list, to: renameText, in: context, ledger: ledger)
          }
        }
      }
      .task {
        await requestAccess()
      }
      .onChange(of: path.count) { _, n in isPushed = n > 0 }
      .onAppear { isPushed = !path.isEmpty }
      .onDisappear { isPushed = false }
      .environment(actions)
      .defaultAppStorage(presentation.defaults)
    }

    // MARK: Pills

    /// The smart lists that are shown, then pinned lists, as the app's shared pills (`PillChip`): one left-aligned row
    /// that scrolls sideways when it doesn't fit, like the Calendar and Alarms switchers. They sit above the List, not
    /// in it: inside a List (a row or a section header) a pill's own long-press menu never opens.
    /// Press, hold and drag a pill to reorder it within its kind (smart lists among themselves, pinned lists among
    /// themselves), as My Lists rows do; the long-press menu has Move Left / Move Right for the same thing.
    @ViewBuilder
    private func pills(_ stats: Stats) -> some View {
      let pinned = sortedLists.filter(\.pinned)
      let smarts = layout.visible
      if !smarts.isEmpty || !pinned.isEmpty {
        PillChipRow {
          ForEach(smarts) { smart in
            reorderable(token: "smart:\(smart.rawValue)") {
              smartChip(smart, stats, id: "smart.\(smart.rawValue)") { path.append(.smart(smart)) }
            } preview: {
              smartChip(smart, stats, id: nil) {}
            } menu: {
              moveButtons(canLeft: smart != smarts.first, canRight: smart != smarts.last) {
                moveSmart(smart, by: $0)
              }
              Button {
                hide(smart)
              } label: {
                Label("Hide “\(smart.title)”", systemImage: "eye.slash")
              }
            } drop: { dragged in
              guard dragged.hasPrefix("smart:"),
                let from = SmartList(rawValue: String(dragged.dropFirst(6)))
              else { return false }
              reorderSmart(PillOrder.move(smarts, from, onto: smart))
              return true
            }
          }
          ForEach(pinned) { list in
            reorderable(token: "list:\(list.name)") {
              pinnedChip(list, stats, id: "pinned.\(list.name)") {
                path.append(.list(list.persistentModelID))
              }
            } preview: {
              pinnedChip(list, stats, id: nil) {}
            } menu: {
              moveButtons(canLeft: list !== pinned.first, canRight: list !== pinned.last) {
                movePinned(list, by: $0)
              }
              Divider()
              listMenu(list)
            } drop: { dragged in
              guard dragged.hasPrefix("list:"),
                let from = pinned.first(where: { $0.name == String(dragged.dropFirst(5)) })
              else { return false }
              reorderPinned(PillOrder.move(pinned, from, onto: list))
              return true
            }
          }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: reorderTick)
        // The same breathing room as the Alarms and Calendar sub-row under the tab pills.
        .padding(.top, 2)
        .padding(.bottom, 6)
      }
    }

    private func smartChip(
      _ smart: SmartList, _ stats: Stats, id: String?, action: @escaping () -> Void
    ) -> some View {
      let n = stats.smart[smart] ?? 0
      return PillChip(
        title: smart.title, count: n, accessibilityText: "\(smart.title), \(reminderCountText(n))",
        identifier: id, leading: { smartMark(smart) }, action: action)
    }

    private func pinnedChip(
      _ list: OneList, _ stats: Stats, id: String?, action: @escaping () -> Void
    ) -> some View {
      let n = stats.open[list.name] ?? 0
      let name = ListName.display(list.name)
      return PillChip(
        title: name, count: n, accessibilityText: "\(name), \(reminderCountText(n))",
        identifier: id, leading: { listMark(list) }, action: action)
    }

    /// A pill that can be picked up: long-press shows its menu, and moving the finger after the lift drags it (the same
    /// way My Lists rows do). While a pill of the same kind hovers over another, a bar shows where it will land.
    private func reorderable<Chip: View, Preview: View, Menu: View>(
      token: String,
      @ViewBuilder chip: () -> Chip,
      @ViewBuilder preview: @escaping () -> Preview,
      @ViewBuilder menu: () -> Menu,
      drop: @escaping (String) -> Bool
    ) -> some View {
      let kind = token.prefix(while: { $0 != ":" })
      let sameKind = dragging.map { $0.prefix(while: { $0 != ":" }) == kind } ?? false
      let after = (dragging.flatMap(pillIndex) ?? 0) < (pillIndex(token) ?? 0)
      return chip()
        .overlay(alignment: after ? .trailing : .leading) {
          if dropTarget == token, sameKind, dragging != token {
            Capsule().fill(Color.accentColor)
              .frame(width: 3, height: PillStyle.Control.height - 8)
              .offset(x: after ? PillStyle.spacing / 2 + 1.5 : -(PillStyle.spacing / 2 + 1.5))
              .allowsHitTesting(false)
              .transition(.opacity)
          }
        }
        .contextMenu { menu() }
        .draggable(token) {
          preview().environment(presentation).onAppear {
            dragging = token
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          }
        }
        .dropDestination(for: String.self) { items, _ in
          defer {
            dragging = nil
            dropTarget = nil
          }
          guard let dragged = items.first else { return false }
          return drop(dragged)
        } isTargeted: { targeted in
          withAnimation(.snappy(duration: 0.15)) {
            if targeted { dropTarget = token } else if dropTarget == token { dropTarget = nil }
          }
        }
    }

    /// Where a token sits in the whole row (smart lists, then pinned lists), to tell which side a drop will land on.
    private func pillIndex(_ token: String) -> Int? {
      let all =
        layout.visible.map { "smart:\($0.rawValue)" }
        + sortedLists.filter(\.pinned).map { "list:\($0.name)" }
      return all.firstIndex(of: token)
    }

    @ViewBuilder
    private func moveButtons(canLeft: Bool, canRight: Bool, move: @escaping (Int) -> Void)
      -> some View
    {
      if canLeft {
        Button {
          move(-1)
        } label: {
          Label("Move Left", systemImage: "arrow.left")
        }
      }
      if canRight {
        Button {
          move(1)
        } label: {
          Label("Move Right", systemImage: "arrow.right")
        }
      }
    }

    private func moveSmart(_ smart: SmartList, by offset: Int) {
      reorderSmart(PillOrder.move(layout.visible, smart, by: offset))
    }

    private func reorderSmart(_ newVisible: [SmartList]) {
      var l = layout
      l.reorderVisible(newVisible)
      withAnimation(.snappy) { smartOrder = l.orderString }
      reorderTick += 1
    }

    private func movePinned(_ list: OneList, by offset: Int) {
      reorderPinned(PillOrder.move(sortedLists.filter(\.pinned), list, by: offset))
    }

    /// Pinned lists have no order of their own: they show in My Lists order, so moving a pill moves the list among the
    /// pinned ones in My Lists too (unpinned lists keep their places).
    private func reorderPinned(_ newPinned: [OneList]) {
      let full = PillOrder.merge(visible: newPinned, into: sortedLists)
      withAnimation(.snappy) {
        ListActions.reorder(full, in: context)
        listsReordered = true
      }
      reorderTick += 1
    }

    /// The small tinted mark of a smart list's pill: its symbol, or for Today the day of the month in a calendar outline.
    @ViewBuilder
    private func smartMark(_ smart: SmartList) -> some View {
      if smart == .today {
        DayMark(color: smart.color)
      } else {
        Image(systemName: smart.symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(smart.color)
      }
    }

    private func listMark(_ list: OneList) -> some View {
      Image(systemName: list.symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(list.color)
    }

    private func hide(_ smart: SmartList) {
      var l = layout
      l.hidden.insert(smart)
      withAnimation(.snappy) { smartHidden = l.hiddenString }
    }

    /// A list's long-press menu, the same on its row and on its pill.
    @ViewBuilder
    private func listMenu(_ list: OneList) -> some View {
      Button {
        renameText = list.name
        renaming = list
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      Button {
        editing = list
      } label: {
        Label("Color & Icon", systemImage: "paintpalette")
      }
      Button {
        withAnimation(.snappy) { ListActions.togglePinned(list, in: context) }
      } label: {
        if list.pinned {
          Label("Unpin", systemImage: "pin.slash")
        } else {
          Label("Pin", systemImage: "pin")
        }
      }
      Divider()
      Button(role: .destructive) {
        askDelete(list)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }

    // MARK: My Lists

    private func myLists(_ stats: Stats) -> some View {
      Section {
        if showsDefaultList(stats) {
          Button {
            path.append(.defaultList)
          } label: {
            ListRow(
              name: "Reminders", color: ReminderPalette.color(6), symbol: "list.bullet",
              count: stats.open[""] ?? 0)
          }
          .moveDisabled(true)
          .deleteDisabled(true)
          .buttonStyle(.plain)
          .stackedCardRow()
          .accessibilityIdentifier("list.default")
        }
        // .onMove lets a row be pressed, held and dragged with no edit mode (iOS 16+), like Apple Reminders:
        // a long press opens the row's menu, and moving the finger without lifting picks the row up instead.
        let ordered = sortedLists
        ForEach(ordered) { list in
          listRow(list, stats: stats)
        }
        .onMove { from, to in
          var reordered = ordered
          reordered.move(fromOffsets: from, toOffset: to)
          ListActions.reorder(reordered, in: context)
          listsReordered = true
        }
        // The system Delete swipe is replaced by the row's own swipe actions; this stays as the List's delete hook.
        .onDelete { offsets in
          if let i = offsets.first, ordered.indices.contains(i) { askDelete(ordered[i]) }
        }

        // An inline row at the end of the list, not a floating button: the app's own bottom bar owns
        // the bottom of the screen, so this stays visible and tappable.
        Button {
          PerformanceTrace.shared.beginPage("list.editor")
          addingList = true
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
              .font(.system(size: 26))
              .frame(width: 30)
            Text("Add List")
          }
          .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(.systemBlue))
        .stackedCardRow()
        .moveDisabled(true)
        .deleteDisabled(true)
        .accessibilityIdentifier("addList")
      } header: {
        Text("My Lists")
          .font(.title3.weight(.bold))
          .foregroundStyle(Color(.label))
          .textCase(nil)
          .accessibilityAddTraits(.isHeader)
      }
    }

    private func listRow(_ list: OneList, stats: Stats) -> some View {
      Button {
        path.append(.list(list.persistentModelID))
      } label: {
        ListRow(
          name: ListName.display(list.name), color: list.color, symbol: list.symbol,
          count: stats.open[list.name] ?? 0, pinned: list.pinned)
      }
      .buttonStyle(.plain)
      .stackedCardRow()
      .accessibilityIdentifier("list.\(list.name)")
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        RowAction.delete(asksFirst: true) { askDelete(list) }
        RowAction.info { editing = list }
        RowAction.pin(list.pinned) { ListActions.togglePinned(list, in: context) }
      }
      .contextMenu {
        listMenu(list)
      } preview: {
        // Keep the presented card a drag source after the context menu opens.
        ListRow(
          name: ListName.display(list.name), color: list.color, symbol: list.symbol,
          count: stats.open[list.name] ?? 0, pinned: list.pinned
        )
        .draggable(list.name)
      }
      // Press, hold and drag: the menu gives way to the system drag (as in Files or Apple Reminders); dropping the
      // row on another row puts it just before that row.
      .draggable(list.name) {
        ListRow(
          name: ListName.display(list.name), color: list.color, symbol: list.symbol,
          count: stats.open[list.name] ?? 0, pinned: list.pinned)
      }
      .dropDestination(for: String.self) { names, _ in
        guard let name = names.first else { return false }
        moveList(named: name, before: list)
        return true
      }
    }

    /// Moves the list called `name` to sit just before `target` (a press-hold-drag and drop in My Lists).
    private func moveList(named name: String, before target: OneList) {
      var ordered = sortedLists
      guard let from = ordered.firstIndex(where: { $0.name == name }), ordered[from] !== target
      else { return }
      let moved = ordered.remove(at: from)
      guard let to = ordered.firstIndex(where: { $0 === target }) else { return }
      ordered.insert(moved, at: to)
      withAnimation(.snappy) {
        ListActions.reorder(ordered, in: context)
        listsReordered = true
      }
    }

    /// Only when the user said "Don't Allow": the first request is iOS's own prompt, shown when this tab first opens.
    private var showsAccessOff: Bool { sync.isDenied }

    /// The default list hides when it has nothing and other lists exist.
    private func showsDefaultList(_ stats: Stats) -> Bool {
      (stats.total[""] ?? 0) > 0 || lists.isEmpty
    }

    private func askDelete(_ list: OneList) {
      pendingDelete = .make(list, context: context)
    }

    /// Counts for the pills and rows, computed in one pass per body.
    @MainActor private struct Stats {
      var smart: [SmartList: Int] = [:]
      var open: [String: Int] = [:]
      var total: [String: Int] = [:]

      init(tasks: [OneTask], now: Date, calendar cal: Calendar) {
        for t in tasks {
          total[t.listName, default: 0] += 1
          if !t.isDone { open[t.listName, default: 0] += 1 }
          for s in SmartList.allCases where s.includes(t, now: now, calendar: cal) {
            smart[s, default: 0] += 1
          }
        }
      }
    }
  }

  /// Today's mark in its pill: the day of the month inside a small tinted calendar outline (no filled circle).
  private struct DayMark: View {
    @Environment(PlannerPresentation.self) private var presentation
    let color: Color

    var body: some View {
      Text("\(presentation.calendar.component(.day, from: presentation.now))")
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(color)
        .minimumScaleFactor(0.7)
        .frame(width: PillStyle.Chip.markSize, height: PillStyle.Chip.markSize)
        .overlay {
          RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(
            color, lineWidth: 1.6)
        }
    }
  }

  /// A list card uses its own color identity with adaptive text, preserving its name, open count and pinned state.
  private struct ListRow: View {
    let name: String
    let color: Color
    let symbol: String
    let count: Int
    var pinned = false

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var minimumHeight = 82

    var body: some View {
      StackedCard(fill: color.opacity(colorScheme == .dark ? 0.30 : 0.18)) {
        HStack(spacing: 12) {
          Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .frame(width: 28)
          Text(name)
            .font(.title3.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
          if pinned {
            Image(systemName: "pin.fill")
              .font(.caption)
          }
          Spacer(minLength: 8)
          Text("\(count)")
            .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
            .fixedSize()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 12)
        .frame(minHeight: minimumHeight)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        pinned
          ? "\(name), pinned, \(reminderCountText(count))" : "\(name), \(reminderCountText(count))")
    }
  }

  extension SmartList {
    /// Today: due today or planned today, plus overdue. Scheduled: has a deadline or a planned time.
    /// All: every open reminder. Flagged: open and flagged. Completed: done.
    @MainActor package func includes(_ task: OneTask, now: Date, calendar: Calendar) -> Bool {
      if self == .completed { return task.isDone }
      guard !task.isDone else { return false }
      switch self {
      case .today:
        return plannerIsOverdue(task, now: now, calendar: calendar)
          || (task.due.map { calendar.isDate($0, inSameDayAs: now) } ?? false)
      case .scheduled: return task.due != nil
      case .all: return true
      case .flagged: return task.flagged
      case .completed: return task.isDone
      }
    }
  }

#endif

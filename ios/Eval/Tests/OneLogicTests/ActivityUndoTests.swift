import XCTest

@testable import TodayCore
@testable import TodayData

/// Undo from Activity beyond reminders: what each alarm change keeps, and when Undo may run.
final class ActivityUndoTests: XCTestCase {
  let seven = AlarmSnapshot(
    hour: 7, minute: 0, label: "Gym", weekdays: [6, 2, 4], snooze: true, sound: "Radar",
    snoozeMinutes: 5)

  private var sevenThirty: AlarmSnapshot {
    var s = seven
    s.minute = 30
    return s
  }

  private var sevenOff: AlarmSnapshot {
    var s = seven
    s.isOn = false
    return s
  }

  func testAlarmSnapshotSortsWeekdaysAndRoundTrips() throws {
    XCTAssertEqual(seven.weekdays, [2, 4, 6], "order never makes two equal alarms differ")
    let change = AlarmChange(before: seven, after: sevenThirty)
    let back = try JSONDecoder().decode(AlarmChange.self, from: JSONEncoder().encode(change))
    XCTAssertEqual(back, change)
    let deleted = AlarmChange(before: seven, after: nil)
    XCTAssertEqual(
      try JSONDecoder().decode(AlarmChange.self, from: JSONEncoder().encode(deleted)), deleted)
  }

  func testAlarmSnapshotSurvivesTheStore() throws {
    let store = try ActivityStore(location: .memory)
    var item = LedgerItem(
      actor: .you, channel: .app, action: .deleted, itemKind: "alarm", title: "Alarm 07:00 · Gym",
      approval: .userMade)
    let data = try JSONEncoder().encode(AlarmChange(before: seven, after: nil))
    item.hasSnapshot = true
    _ = try store.insert([item.event(snapshot: data)])
    let stored = try XCTUnwrap(store.snapshot(uid: item.id.uuidString))
    XCTAssertEqual(
      try JSONDecoder().decode(AlarmChange.self, from: stored).before, seven)
    let page = try store.page(ActivityQuery(tiers: [.changes]), limit: 5)
    XCTAssertEqual(page.map { LedgerItem(event: $0).hasSnapshot }, [true])
    XCTAssertNil(page.first?.props.range(of: "Gym"), "labels never go in props")
  }

  func testDeleteRecreatesWhatWasThere() {
    let change = AlarmChange(before: seven, after: nil)
    XCTAssertEqual(AlarmUndo.step(for: .deleted, change: change, current: nil), .recreate(seven))
    XCTAssertNil(
      AlarmUndo.step(for: .deleted, change: AlarmChange(before: nil, after: nil), current: nil))
  }

  func testAddIsTakenAwayOnlyWhileUnchanged() {
    let change = AlarmChange(before: nil, after: seven)
    XCTAssertEqual(AlarmUndo.step(for: .created, change: change, current: seven), .remove)
    XCTAssertNil(
      AlarmUndo.step(for: .created, change: change, current: sevenThirty), "edited since")
    XCTAssertNil(AlarmUndo.step(for: .created, change: change, current: nil), "already gone")
  }

  func testEditAndSwitchPutTheOldSettingsBack() {
    let edit = AlarmChange(before: seven, after: sevenThirty)
    XCTAssertEqual(
      AlarmUndo.step(for: .edited, change: edit, current: sevenThirty), .restore(seven))
    XCTAssertEqual(
      AlarmUndo.step(for: .moved, change: edit, current: sevenThirty), .restore(seven),
      "Siri's alarm update")
    XCTAssertNil(AlarmUndo.step(for: .edited, change: edit, current: seven), "changed since")
    XCTAssertNil(AlarmUndo.step(for: .edited, change: edit, current: nil), "deleted since")
    let off = AlarmChange(before: seven, after: sevenOff)
    XCTAssertEqual(
      AlarmUndo.step(for: .switchedOff, change: off, current: sevenOff), .restore(seven))
    let on = AlarmChange(before: sevenOff, after: seven)
    XCTAssertEqual(
      AlarmUndo.step(for: .switchedOn, change: on, current: seven), .restore(sevenOff))
    XCTAssertNil(
      AlarmUndo.step(for: .switchedOn, change: on, current: sevenOff), "switched back already")
    XCTAssertNil(AlarmUndo.step(for: .settled, change: edit, current: sevenThirty))
  }

  func testUndoIsOfferedForAlarmsWithASnapshot() {
    func can(
      _ a: LedgerAction, kind: String = "alarm", approval: LedgerApproval = .userMade,
      snapshot: Bool = true, undone: Bool = false
    ) -> Bool {
      LedgerFormat.canUndo(
        action: a, itemKind: kind, approval: approval, hasItem: false, hasSnapshot: snapshot,
        alreadyUndone: undone)
    }
    for a: LedgerAction in [.created, .deleted, .edited, .moved, .switchedOn, .switchedOff] {
      XCTAssertTrue(can(a), "\(a)")
      XCTAssertFalse(can(a, snapshot: false), "\(a): an old row, or past 30 days")
      XCTAssertFalse(can(a, undone: true), "\(a): once undone, no second Undo")
    }
    XCTAssertTrue(can(.created, approval: .asked), "an alarm added from an AI card")
    XCTAssertFalse(can(.renamed), "an AI card's title edit keeps its own toast")
    XCTAssertFalse(can(.undone))
  }

  func testSettleAndItsReverseHaveNoUndo() {
    for a: LedgerAction in [.settled, .snoozed, .restored] {
      XCTAssertFalse(
        LedgerFormat.canUndo(
          action: a, itemKind: "focus", approval: .userMade, hasItem: true, hasSnapshot: true,
          alreadyUndone: false))
    }
  }

  func testNewActionsReadWell() {
    XCTAssertEqual(LedgerFormat.headline(.edited, title: "Alarm 07:00"), "Changed “Alarm 07:00”")
    XCTAssertEqual(
      LedgerFormat.headline(.switchedOff, title: "Alarm 07:00"), "Turned off “Alarm 07:00”")
    XCTAssertEqual(LedgerAction(rawValue: "switchedOn"), .switchedOn)
  }

  // MARK: Lists

  let groceries = ListSnapshot(name: "Groceries", colorIndex: 3, symbol: "cart", order: 2)

  private var shops: ListSnapshot {
    var s = groceries
    s.name = "Shops"
    return s
  }

  private var greenBag: ListSnapshot {
    var s = groceries
    s.colorIndex = 8
    s.symbol = "bag"
    return s
  }

  func testListChangeKeepsItsRemindersThroughTheStore() throws {
    let change = ListChange(
      before: groceries, after: nil,
      tasks: [TaskSnapshot(title: "Milk", listName: "Groceries", flagged: true)])
    let back = try JSONDecoder().decode(ListChange.self, from: JSONEncoder().encode(change))
    XCTAssertEqual(back, change)
  }

  func testListDeleteComesBackWithItsReminders() {
    let milk = TaskSnapshot(title: "Milk", listName: "Groceries")
    let change = ListChange(before: groceries, after: nil, tasks: [milk])
    XCTAssertEqual(
      ListUndo.step(for: .deleted, change: change, current: nil), .recreate(groceries, [milk]))
    XCTAssertNil(
      ListUndo.step(for: .deleted, change: change, current: nil, nameTaken: true),
      "a new list took the name")
    XCTAssertNil(
      ListUndo.step(for: .deleted, change: ListChange(before: nil, after: nil), current: nil))
  }

  func testNewListIsTakenAwayOnlyWhileEmpty() {
    let change = ListChange(before: nil, after: groceries)
    XCTAssertEqual(ListUndo.step(for: .created, change: change, current: groceries), .remove)
    XCTAssertNil(
      ListUndo.step(for: .created, change: change, current: groceries, taskCount: 1),
      "reminders were added since")
    XCTAssertNil(ListUndo.step(for: .created, change: change, current: shops), "renamed since")
    XCTAssertNil(ListUndo.step(for: .created, change: change, current: nil), "already gone")
  }

  func testRenameAndLookGoBack() {
    let rename = ListChange(before: groceries, after: shops)
    XCTAssertEqual(
      ListUndo.step(for: .renamed, change: rename, current: shops), .rename("Groceries"))
    XCTAssertNil(ListUndo.step(for: .renamed, change: rename, current: groceries), "changed since")
    XCTAssertNil(
      ListUndo.step(for: .renamed, change: rename, current: shops, nameTaken: true),
      "another list is called Groceries now")
    let look = ListChange(before: groceries, after: greenBag)
    XCTAssertEqual(
      ListUndo.step(for: .edited, change: look, current: greenBag),
      .restyle(colorIndex: 3, symbol: "cart"))
    XCTAssertNil(ListUndo.step(for: .edited, change: look, current: groceries), "changed since")
    XCTAssertNil(ListUndo.step(for: .settled, change: look, current: greenBag))
  }

  func testUndoIsOfferedForListsWithASnapshot() {
    for a: LedgerAction in [.created, .deleted, .renamed, .edited] {
      XCTAssertTrue(
        LedgerFormat.canUndo(
          action: a, itemKind: "list", approval: .userMade, hasItem: false, hasSnapshot: true,
          alreadyUndone: false), "\(a)")
      XCTAssertFalse(
        LedgerFormat.canUndo(
          action: a, itemKind: "list", approval: .userMade, hasItem: true, hasSnapshot: false,
          alreadyUndone: false), "\(a): an older row, a list in Apple Reminders, or past 30 days")
    }
  }

  // MARK: Events

  func testOnlyAOneOffWithNobodyElseOnItCanComeBack() {
    XCTAssertTrue(EventUndo.canRestore(repeats: false, inAppleCalendar: true, attendees: 0))
    XCTAssertFalse(
      EventUndo.canRestore(repeats: false, inAppleCalendar: true, attendees: 3),
      "adding it back would invite people again")
    XCTAssertFalse(
      EventUndo.canRestore(repeats: false, inAppleCalendar: true, attendees: nil),
      "the event could not be read")
    XCTAssertFalse(
      EventUndo.canRestore(repeats: true, inAppleCalendar: true, attendees: 0), "a series")
    XCTAssertFalse(EventUndo.canRestore(repeats: true, inAppleCalendar: false, attendees: 0))
    XCTAssertFalse(
      EventDeletePrompt.asksFirst(repeats: false, inAppleCalendar: false, attendees: nil))
    XCTAssertFalse(EventDeletePrompt.asksFirst(repeats: false, inAppleCalendar: true, attendees: 0))
    XCTAssertTrue(EventDeletePrompt.asksFirst(repeats: false, inAppleCalendar: true, attendees: 2))
    XCTAssertTrue(
      EventDeletePrompt.asksFirst(repeats: false, inAppleCalendar: true, attendees: nil))
    XCTAssertTrue(
      EventDeletePrompt.asksFirst(repeats: true, inAppleCalendar: false, attendees: nil))
    XCTAssertTrue(EventDeletePrompt.allowsFullSwipe(canDelete: true, repeats: false))
    XCTAssertFalse(EventDeletePrompt.allowsFullSwipe(canDelete: false, repeats: false))
    XCTAssertFalse(EventDeletePrompt.allowsFullSwipe(canDelete: true, repeats: true))
    XCTAssertEqual(
      EventDeletePrompt.message(title: "Sync", repeats: false, attendees: 1),
      "Delete “Sync”? This changes its source. 1 attendee gets a cancellation, and Undo can’t recall it."
    )
    XCTAssertEqual(
      EventDeletePrompt.message(title: "Sync", repeats: true, attendees: 3),
      "“Sync” repeats. 3 attendees get a cancellation, and Undo can’t recall it.")
    XCTAssertEqual(
      EventDeletePrompt.message(title: "Sync", repeats: false, attendees: nil),
      "Delete “Sync”? This changes its source.")
    XCTAssertTrue(
      EventUndo.canRestore(repeats: false, inAppleCalendar: false, attendees: nil),
      "a Today-only event")
  }

  func testEventSnapshotRoundTripsAndOnlyDeletesAreUndone() throws {
    let s = EventSnapshot(
      title: "Dentist", start: Date(timeIntervalSince1970: 1_800_000_000), durationMinutes: 45,
      calendarName: "Home", externalID: "EK-1")
    XCTAssertEqual(try JSONDecoder().decode(EventSnapshot.self, from: JSONEncoder().encode(s)), s)
    func can(
      _ a: LedgerAction, snapshot: Bool = true, approval: LedgerApproval = .userMade
    ) -> Bool {
      LedgerFormat.canUndo(
        action: a, itemKind: "event", approval: approval, hasItem: false, hasSnapshot: snapshot,
        alreadyUndone: false)
    }
    XCTAssertTrue(can(.deleted))
    XCTAssertFalse(can(.deleted, snapshot: false), "a series, attendees, or an old row")
    XCTAssertFalse(can(.deleted, approval: .observed), "deleted in Apple Calendar")
    XCTAssertFalse(can(.moved), "an AI move goes to attendees; no Undo from Activity")
    XCTAssertFalse(can(.created))
    XCTAssertEqual(EventUndo.restoresAsNew, "Restores as a new event")
  }
}

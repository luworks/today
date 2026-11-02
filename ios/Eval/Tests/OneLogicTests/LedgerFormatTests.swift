import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class LedgerFormatTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c
  }()

  func testActorsRoundTripAndFilter() {
    let all: [LedgerActor] = [
      .you, .todayAI, .siri, .shortcut, .share, .agent("Apple Reminders"), .agent("Trip"),
    ]
    for a in all { XCTAssertEqual(LedgerActor(raw: a.raw), a) }
    XCTAssertEqual(LedgerActor(raw: "agent:Trip").name, "Trip")
    XCTAssertEqual(LedgerActor.todayAI.name, "Today AI")
    XCTAssertTrue(ActivityFilter.ai.includes(.todayAI))
    XCTAssertFalse(ActivityFilter.ai.includes(.you))
    XCTAssertTrue(ActivityFilter.you.includes(.you))
    for a: LedgerActor in [.siri, .shortcut, .share, .agent("Apple Calendar")] {
      XCTAssertTrue(ActivityFilter.agents.includes(a), "\(a) is an agent")
      XCTAssertFalse(ActivityFilter.you.includes(a))
    }
    XCTAssertTrue(all.allSatisfy(ActivityFilter.all.includes))
  }

  func testHeadlineAndBeforeAfter() {
    XCTAssertEqual(LedgerFormat.headline(.planned, title: "Buy milk"), "Planned “Buy milk”")
    XCTAssertEqual(LedgerFormat.headline(.deleted, title: "Buy milk"), "Deleted “Buy milk”")
    XCTAssertEqual(
      LedgerFormat.change(before: "Not planned", after: "Today 10:00"), "Not planned → Today 10:00")
    XCTAssertEqual(LedgerFormat.change(before: "", after: "Today 10:00"), "Today 10:00")
    XCTAssertEqual(LedgerFormat.change(before: "", after: ""), "")
    XCTAssertEqual(LedgerFormat.time(nil), "Not planned")
    XCTAssertEqual(LedgerFormat.time(nil, none: "No date"), "No date")
    XCTAssertEqual(LedgerFormat.time(cal.startOfDay(for: .now), calendar: cal), "Today")
  }

  func testUndoIsOfferedOnlyForReminderChangesTodayCanPutBack() {
    func can(
      _ a: LedgerAction, kind: String = "task", approval: LedgerApproval = .userMade,
      item: Bool = true,
      snapshot: Bool = false, undone: Bool = false
    ) -> Bool {
      LedgerFormat.canUndo(
        action: a, itemKind: kind, approval: approval, hasItem: item, hasSnapshot: snapshot,
        alreadyUndone: undone)
    }
    XCTAssertTrue(can(.redated))
    XCTAssertFalse(can(.planned), "retired planned-time entries cannot be undone")
    XCTAssertFalse(can(.moved))
    XCTAssertFalse(can(.unscheduled))
    XCTAssertTrue(can(.completed))
    XCTAssertTrue(can(.renamed))
    XCTAssertFalse(can(.renamed, item: false), "renaming Undo never resurrects a missing reminder")
    XCTAssertFalse(can(.renamed, kind: "alarm"), "alarm title Undo uses its toast")
    XCTAssertTrue(can(.deleted, item: false, snapshot: true))
    XCTAssertFalse(can(.deleted, item: false, snapshot: false))
    XCTAssertFalse(can(.planned, undone: true), "once undone, no second Undo")
    XCTAssertFalse(can(.planned, item: false), "the reminder is gone")
    XCTAssertFalse(
      can(.deleted, approval: .observed, snapshot: true),
      "deleted in Apple Reminders: not ours to undo")
    XCTAssertFalse(can(.moved, kind: "event"))
    XCTAssertFalse(can(.undone))
    XCTAssertFalse(can(.granted, kind: "grant"))
  }

  func testGroupsByDayNewestFirst() {
    let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
    let dates = [
      now.addingTimeInterval(-3600), now.addingTimeInterval(-26 * 3600),
      now.addingTimeInterval(-60),
      now.addingTimeInterval(-5 * 86_400),
    ]
    let groups = LedgerFormat.groupByDay(dates, date: { $0 }, now: now, calendar: cal)
    XCTAssertEqual(groups.map(\.title).prefix(2), ["Today", "Yesterday"])
    XCTAssertEqual(groups.count, 3)
    XCTAssertEqual(groups[0].items, [dates[2], dates[0]], "newest first within a day")
  }

  func testTaskSnapshotRoundTrips() throws {
    let s = TaskSnapshot(
      title: "Buy milk", due: .now, listName: "Home", flagged: true,
      checklist: [ChecklistItem(title: "Oat")])
    let back = try JSONDecoder().decode(TaskSnapshot.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(back, s)
  }
}

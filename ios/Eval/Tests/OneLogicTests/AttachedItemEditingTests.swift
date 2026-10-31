import Foundation
import XCTest

@testable import TodayCore

final class AttachedItemEditingTests: XCTestCase {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
  }
  private var items: [EditItem] {
    [
      EditItem(id: "a", type: "task", title: "Milk", start: now, minutes: 0, attendees: 0),
      EditItem(id: "b", type: "task", title: "Milk", start: now, minutes: 0, attendees: 0),
      EditItem(id: "e", type: "event", title: "Meeting", start: now, minutes: 30, attendees: 1),
    ]
  }
  private func parse(_ text: String, id: String? = "a") -> AttachedItemEdit? {
    FastLane.attachedEdit(text, attachedItemID: id, items: items, now: now, calendar: calendar)
  }

  func testMoveInBothLanguagesUsesAttachedID() {
    let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 16))!
    for text in ["Move it to 4pm", "把它改到下午4点"] {
      XCTAssertEqual(parse(text)?.target, "a", text)
      XCTAssertEqual(parse(text)?.operation, .move(expected), text)
    }
  }

  func testOwnerSentenceMovesAttachedItemTomorrowAtEleven() {
    let text = "请把这个改成明天上午 11 点，我需要去审核一下的吧"
    let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 11))!
    let route = SentenceRoute.route(
      text, items: items, now: now, calendar: calendar, attachedItemID: "a")
    guard case .attachedEdit(let edit) = route else { return XCTFail("Expected attached edit") }
    XCTAssertEqual(edit.target, "a")
    XCTAssertEqual(edit.operation, .move(expected))
  }

  func testRenameDeleteAndDoneInBothLanguages() {
    for text in ["Rename it to Groceries", "把它改名为Groceries"] {
      XCTAssertEqual(parse(text)?.operation, .rename("Groceries"), text)
    }
    for text in ["Delete it", "把它删除"] {
      XCTAssertEqual(parse(text)?.operation, .delete, text)
    }
    for text in ["Mark it as done", "把它标记为已完成"] {
      XCTAssertEqual(parse(text)?.operation, .done, text)
    }
  }

  func testUnavailableOrDuplicateIDAndWrongTypeDoNotResolve() {
    XCTAssertNil(parse("Delete it", id: nil)?.operation)
    XCTAssertNil(parse("Delete it", id: "missing")?.operation)
    XCTAssertNil(parse("Complete it", id: "e")?.operation)
    let duplicate = items + [items[0]]
    XCTAssertNil(
      FastLane.attachedEdit(
        "Delete it", attachedItemID: "a", items: duplicate, now: now, calendar: calendar)?.operation
    )
  }

  func testQuestionsOtherTargetsAndMultipleActionsAreNotApplied() {
    XCTAssertNil(parse("Should I delete it?"))
    XCTAssertNil(parse("Delete Milk"))
    XCTAssertNil(parse("Delete it and then call Sam")?.operation)
    XCTAssertNil(parse("把它改到明天然后删除它")?.operation)
  }

  func testSentenceRoutePassesAttachmentAndKeepsOrdinaryRoute() {
    let route = SentenceRoute.route(
      "Delete it", items: items, now: now, calendar: calendar, attachedItemID: "b")
    guard case .attachedEdit(let edit) = route else { return XCTFail("Expected attached edit") }
    XCTAssertEqual(edit.target, "b")
    XCTAssertEqual(edit.operation, .delete)
    XCTAssertFalse(route.isActionable, "The app must integrate the preview before suggesting it")
    if case .edit(let edit) = SentenceRoute.route(
      "Delete it", items: items, now: now, calendar: calendar)
    {
      XCTAssertEqual(edit.op, .clarify)
    } else {
      XCTFail("Ordinary chat must retain its existing route")
    }
  }

  func testAttachedEventMoveAndDeleteUseIdentityRatherThanDuplicateTitle() {
    let events = [
      EditItem(
        id: "apple:first", type: "event", title: "Meeting", start: now, minutes: 30, attendees: 0),
      EditItem(
        id: "apple:second", type: "event", title: "Meeting", start: now, minutes: 30, attendees: 0),
    ]
    let moved = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 16))!
    let move = FastLane.attachedEdit(
      "Move it to 4pm", attachedItemID: "apple:second", items: events, now: now, calendar: calendar)
    XCTAssertEqual(move?.target, "apple:second")
    XCTAssertEqual(move?.operation, .move(moved))
    let delete = FastLane.attachedEdit(
      "Delete it", attachedItemID: "apple:second", items: events, now: now, calendar: calendar)
    XCTAssertEqual(delete?.target, "apple:second")
    XCTAssertEqual(delete?.operation, .delete)
  }

  func testAttachedEventRelativeMoveUsesEventStartNotCurrentTime() {
    let start = now.addingTimeInterval(2 * 3600)
    let event = EditItem(
      id: "apple:event", type: "event", title: "Meeting", start: start, minutes: 60, attendees: 0)
    let edit = FastLane.attachedEdit(
      "Postpone it by one hour", attachedItemID: event.id, items: [event], now: now,
      calendar: calendar)
    XCTAssertEqual(edit?.target, event.id)
    XCTAssertEqual(edit?.operation, .move(start.addingTimeInterval(3600)))
  }

}

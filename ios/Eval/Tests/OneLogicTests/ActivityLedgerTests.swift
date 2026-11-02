import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The changes ledger on the Activity store: how a ledger line maps to an event and back.
final class ActivityLedgerTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  let now = Date(timeIntervalSince1970: 1_792_000_000)

  func testItemRoundTripsThroughAnEvent() {
    var item = LedgerItem(
      date: now, actor: .todayAI, channel: .automatic, action: .moved, itemKind: "task",
      title: "買牛奶",
      before: "Today 09:00", after: "Today 11:00", approval: .autoUnderGrant)
    item.itemRef = "{\"id\":1}"
    item.beforeDate = now
    item.afterDate = now.addingTimeInterval(7200)
    item.undoOf = UUID()
    let event = item.event(snapshot: Data([1, 2]), calendar: cal)
    XCTAssertEqual(event.kind, "change.moved")
    XCTAssertEqual(event.tier, 1)
    XCTAssertEqual(event.channel, "automatic", "the store keeps a slug, not the display name")
    XCTAssertEqual(event.approval, "auto")
    XCTAssertEqual(event.uid, item.id.uuidString)
    var back = LedgerItem(event: event)
    XCTAssertFalse(back.hasSnapshot, "hasSnapshot is a read-side flag set by the store")
    back.hasSnapshot = false
    XCTAssertEqual(back, item)
  }

  func testGrantsUseTheGrantKindAndEveryActionRoundTrips() {
    for action in [
      LedgerAction.created, .completed, .reopened, .deleted, .planned, .moved, .unscheduled,
      .redated, .edited, .switchedOn, .switchedOff, .undone, .granted, .revoked,
    ] {
      let item = LedgerItem(
        date: now, actor: .you, channel: .app, action: action,
        itemKind: action == .granted ? "grant" : "task",
        title: "x", approval: .userMade)
      let e = item.event()
      XCTAssertEqual(
        e.kind.hasPrefix(action == .granted || action == .revoked ? "grant." : "change."), true,
        e.kind)
      XCTAssertEqual(LedgerItem(event: e).actionValue, action)
    }
    for c in LedgerChannel.allCases { XCTAssertEqual(LedgerChannel(slug: c.slug), c) }
  }
}

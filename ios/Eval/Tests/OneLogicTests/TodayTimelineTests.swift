import CoreGraphics
import Foundation
import Testing

@testable import TodayCore

struct TodayTimelineTests {
  typealias Item = TodayTimeline.Item
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
  var midnight: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }

  func at(_ hour: Int, _ minute: Int = 0) -> Date {
    midnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  func event(_ hour: Int, _ minute: Int, minutes: Int) -> Item {
    Item(start: at(hour, minute), end: at(hour, minute + minutes), kind: .event)
  }

  @Test func anEventThatEndedBeforeEntryLeavesTheList() {
    let entry = at(9)
    #expect(!TodayTimeline.isListed(event(8, 0, minutes: 30), entry: entry))
    #expect(TodayTimeline.isListed(event(8, 30, minutes: 60), entry: entry))
    #expect(!TodayTimeline.isListed(Item(start: at(8), kind: .alarm), entry: entry))
  }

  @Test func whatEndsAfterEntryStaysUntilTheNextEntry() {
    let item = event(9, 0, minutes: 30)
    #expect(TodayTimeline.isListed(item, entry: at(9, 10)))
    #expect(!TodayTimeline.isListed(item, entry: at(10)))
  }

  @Test func openPastRemindersStayAndDoneOnesLeaveOnlyAtEntry() {
    let entry = at(12)
    #expect(TodayTimeline.isListed(Item(start: at(8), kind: .reminder), entry: entry))
    #expect(
      TodayTimeline.isListed(Item(start: at(8), kind: .reminder, isDone: true), entry: entry))
    #expect(
      !TodayTimeline.isListed(
        Item(start: at(8), kind: .reminder, isDone: true, doneAtEntry: true), entry: entry))
    #expect(
      TodayTimeline.isListed(
        Item(start: at(8), kind: .reminder, isDone: true, doneAtEntry: true), entry: nil))
  }

  @Test func onlyOpenPastRemindersAreLate() {
    let now = at(12)
    #expect(TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder, isDone: true), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(13), kind: .reminder), now: now))
    #expect(!TodayTimeline.isOpenPast(event(8, 0, minutes: 30), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder), now: nil))
  }

  @Test func rowsKeepTimeOrderWithFreeAfterItemsAndNowInPlace() {
    let items = [
      Item(start: at(14), kind: .reminder), event(9, 0, minutes: 60),
      Item(start: at(7), kind: .reminder),
    ]
    let free = [DateInterval(start: at(10), end: at(14)), DateInterval(start: at(9), end: at(9))]
    let rows = TodayTimeline.rows(items: items, free: free, now: at(11), entry: at(9, 30))
    #expect(rows == [.item(2), .item(1), .free(1), .free(0), .now, .item(0)])
  }

  @Test func nowGoesLastWhenTheDayIsOverAndIsAbsentOnOtherDays() {
    let items = [Item(start: at(7), kind: .reminder)]
    #expect(
      TodayTimeline.rows(items: items, free: [], now: at(23), entry: at(23)) == [.item(0), .now])
    #expect(TodayTimeline.rows(items: items, free: [], now: nil, entry: nil) == [.item(0)])
  }

  @Test func rowsDropWhatEndedBeforeEntry() {
    let items = [event(8, 0, minutes: 30), Item(start: at(8), kind: .reminder)]
    #expect(
      TodayTimeline.rows(items: items, free: [], now: at(10), entry: at(9)) == [.item(1), .now])
  }

  @Test func viewportSpansTheVisibleRows() {
    let frames = [
      TodayTimeline.Frame(span: DateInterval(start: at(7), end: at(7)), minY: 0, maxY: 44),
      TodayTimeline.Frame(span: DateInterval(start: at(9), end: at(10)), minY: 44, maxY: 88),
      TodayTimeline.Frame(span: DateInterval(start: at(12), end: at(12)), minY: 88, maxY: 132),
      TodayTimeline.Frame(span: DateInterval(start: at(18), end: at(19)), minY: 400, maxY: 444),
    ]
    #expect(
      TodayTimeline.viewport(frames, top: 40, bottom: 200)
        == DateInterval(start: at(9), end: at(12)))
    #expect(TodayTimeline.viewport(frames, top: 500, bottom: 600) == nil)
    #expect(
      TodayTimeline.viewport(frames, top: 0, bottom: 500)
        == DateInterval(start: at(7), end: at(19)))
  }

  @Test func scrollTargetIsTheFirstRowStillRunningAtThatTime() {
    let spans = [
      DateInterval(start: at(7), end: at(7)), DateInterval(start: at(9), end: at(10)),
      DateInterval(start: at(12), end: at(12)),
    ]
    #expect(TodayTimeline.scrollTarget(for: at(6), in: spans) == 0)
    #expect(TodayTimeline.scrollTarget(for: at(9, 30), in: spans) == 1)
    #expect(TodayTimeline.scrollTarget(for: at(11), in: spans) == 2)
    #expect(TodayTimeline.scrollTarget(for: at(22), in: spans) == 2)
    #expect(TodayTimeline.scrollTarget(for: at(9), in: []) == nil)
  }

  @Test func ribbonStartsAtSixOrTheEarliestHour() {
    let day = at(12)
    #expect(
      TodayTimeline.ribbonRange(items: [], day: day, calendar: calendar)
        == DateInterval(start: at(6), end: at(24)))
    #expect(
      TodayTimeline.ribbonRange(
        items: [Item(start: at(4, 30), kind: .alarm)], day: day, calendar: calendar)
        == DateInterval(start: at(4), end: at(24)))
    #expect(
      TodayTimeline.ribbonRange(
        items: [Item(start: at(-2), kind: .event)], day: day, calendar: calendar
      ).start == at(0))
  }

  @Test func ribbonFractionIsClamped() {
    let range = DateInterval(start: at(6), end: at(24))
    #expect(TodayTimeline.date(at: 0.5, in: range) == at(15))
    #expect(TodayTimeline.date(at: -1, in: range) == at(6))
    #expect(TodayTimeline.date(at: 2, in: range) == at(24))
  }
}

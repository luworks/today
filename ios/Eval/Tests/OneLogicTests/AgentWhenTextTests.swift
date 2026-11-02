import XCTest

@testable import TodayCore

/// The date/time words the agent passes in `when_text` (docs/qa/agent-p3-eval-20261101.md, Must fix 4–8):
/// the parser alone, without the sentence around them.
final class AgentWhenTextTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()
  /// The holdout clock: Wed 2026-11-04 09:00.
  lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9))!

  private func day(_ c: Capture) -> String {
    let d = cal.dateComponents([.month, .day], from: c.day)
    return "\(d.month!)/\(d.day!)"
  }

  /// Must fix 4: an alarm's ambiguous hour is in the morning, as in Apple Clock, even when the words
  /// handed over carry no "alarm" ("6:15 tomorrow").
  func testAlarmWordsDefaultToTheMorning() {
    for text in ["6:15 tomorrow", "tomorrow 6:15", "6:15"] {
      let c = CaptureParser.parse(text, now: now, calendar: cal, alarm: true)
      XCTAssertEqual(c.hour, 6, text)
      XCTAssertEqual(c.minute, 15, text)
      XCTAssertEqual(day(c), "11/5", text)
    }
    // An explicit half of the day still wins.
    XCTAssertEqual(CaptureParser.parse("6:15pm", now: now, calendar: cal, alarm: true).hour, 18)
    XCTAssertEqual(CaptureParser.parse("今晚6点", now: now, calendar: cal, alarm: true).hour, 18)
    // A reminder keeps the afternoon default for 1–6 ("at 4" almost always means 16:00).
    XCTAssertEqual(CaptureParser.parse("6:15 tomorrow", now: now, calendar: cal).hour, 18)
  }

  /// Must fix 5: "from X to Y" gives the start and the length, in English and Chinese.
  func testFromToGivesAStartAndALength() {
    for text in ["Monday from 9am to 5pm", "周一从9点到5点"] {
      let c = CaptureParser.parse(text, now: now, calendar: cal)
      XCTAssertEqual(day(c), "11/9", text)
      XCTAssertEqual(c.hour, 9, text)
      XCTAssertEqual(c.durationMinutes, 480, text)
    }
    let titled = CaptureParser.parse("周一从9点到5点团建", now: now, calendar: cal)
    XCTAssertEqual(titled.title, "团建")
  }

  /// Must fix 7: "今天12点半" is 12:30, like "12点半".
  func testTodayHalfPastTwelve() {
    for text in ["今天12点半", "12点半", "今天 12:30"] {
      let c = CaptureParser.parse(text, now: now, calendar: cal)
      XCTAssertEqual(c.hour, 12, text)
      XCTAssertEqual(c.minute, 30, text)
    }
  }
}

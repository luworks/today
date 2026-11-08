import XCTest

@testable import TodayCore

/// Product principles 1–6 (CLAUDE.md) as ActionPolicy rules (docs/engineering/ai-agent-architecture.md §3 O1, §4.2).
final class ActionPolicyTests: XCTestCase {
  private typealias R = ActionPolicy.Request

  private func oneOff(
    source: ActionPolicy.Source = .fastLane, words: ActionPolicy.Words = .user
  ) -> R {
    R(
      tool: .proposeCreate, source: source, words: words, kind: .reminder, fields: [.title, .due],
      askedForAction: true)
  }

  // MARK: Tool metadata

  func testTwelveToolsWithReadsAndWritesSeparated() {
    XCTAssertEqual(AgentTool.allCases.count, 12)
    XCTAssertEqual(
      Set(AgentTool.allCases.filter { !$0.isWrite }),
      [.getAgenda, .findItems, .getItem, .freeTime, .listLists, .getActivity])
    XCTAssertEqual(AgentTool.proposeDelete.metadata.effect, .delete)
    XCTAssertEqual(AgentTool.proposeCreate.metadata.audience, .selfOnly)
    XCTAssertEqual(AgentTool.proposeEdit.metadata.audience, .mayReachOthers)
    XCTAssertTrue(AgentTool.allCases.allSatisfy { $0.metadata.reversible })
    XCTAssertEqual(
      ActionPolicy.tier(R(tool: .getAgenda, source: .agent, kind: .event)),
      .refuse(.readOnlyTool))
  }

  // MARK: Principle 1: clear requests are applied with Undo (owner decision 2026-11-02)

  func testAClearRequestInTheUsersOwnWordsIsAppliedWithUndo() {
    XCTAssertEqual(ActionPolicy.tier(oneOff()), .direct)
    XCTAssertEqual(ActionPolicy.tier(oneOff(source: .agent)), .direct)
    // Siri confirms in its own intent UI; words written by others are only shown.
    XCTAssertEqual(ActionPolicy.tier(oneOff(source: .siri)), .preview)
    XCTAssertEqual(ActionPolicy.tier(oneOff(words: .derived)), .preview)
    // A question or chit-chat never writes by itself.
    var question = oneOff(source: .agent)
    question.askedForAction = false
    XCTAssertEqual(ActionPolicy.tier(question), .preview)
  }

  func testAlarmsRecurrenceEventsEditsAndTidyAreAppliedToo() {
    var repeating = oneOff(source: .agent)
    repeating.fields.insert(.repeatRule)
    var alarm = oneOff(source: .agent)
    alarm.kind = .alarm
    alarm.fields.insert(.ringsAsAlarm)
    var event = oneOff(source: .agent)
    event.kind = .event
    var edit = oneOff(source: .agent)
    edit.tool = .proposeEdit
    var tidy = oneOff(source: .agent)
    tidy.tool = .proposeTidy
    var reminderDelete = oneOff(source: .agent)
    reminderDelete.tool = .proposeDelete
    var move = R(
      tool: .proposeEdit, source: .agent, kind: .event, fields: [.start], askedForAction: true,
      userAskedToMoveEvent: true)
    var soloDelete = R(tool: .proposeDelete, source: .agent, kind: .event, askedForAction: true)
    for request in [repeating, alarm, event, edit, tidy, reminderDelete, move, soloDelete] {
      XCTAssertEqual(ActionPolicy.tier(request), .direct, "\(request)")
    }
    move.attendees = 1
    soloDelete.affectsSeries = true
    XCTAssertNotEqual(ActionPolicy.tier(move), .direct)
    XCTAssertNotEqual(ActionPolicy.tier(soloDelete), .direct)
  }

  func testOnlyMessagesThatAskForAnActionCount() {
    for text in [
      "今天下午 5 点的时候提醒我，就绝对不能吃饭了", "明天早上7点叫醒我", "Set an alarm for 6:30 tomorrow",
      "Remind me to call Alex tomorrow at 11am", "把牙医改到4点", "move the dentist to 4pm",
      "Could you remind me to stretch at 4pm?", "能帮我明天8点设个闹钟吗？", "整理逾期",
    ] {
      XCTAssertTrue(ActionPolicy.asksForAction(text), text)
    }
    for text in [
      "明天有什么安排？", "Should I move the dentist?", "What's on tomorrow?", "谢谢",
      "我已经设好闹钟了", "我妈说她明天要提醒自己吃药", "Can you explain how alarms work?",
      "Don't add anything, just chatting", "",
    ] {
      XCTAssertFalse(ActionPolicy.asksForAction(text), text)
    }
  }

  func testMissingInformationIsAskedNotGuessed() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertTrue(ActionPolicy.autoAddReady(Capture(title: "Milk", day: now, hasDay: false)))
    var alarm = Capture(title: "Gym", day: now, hasDay: true)
    alarm.ringsAsAlarm = true
    XCTAssertFalse(ActionPolicy.autoAddReady(alarm), "an alarm needs its time")
    alarm.hour = 7
    XCTAssertTrue(ActionPolicy.autoAddReady(alarm))
    var event = Capture(title: "Lunch", day: now, hasDay: false)
    event.kind = .event
    XCTAssertFalse(ActionPolicy.autoAddReady(event), "an event needs its day")
    event.hasDay = true
    XCTAssertTrue(ActionPolicy.autoAddReady(event))
  }

  func testTheReplySaysWhatWasDoneNeverTapAdd() {
    let alarm = AgentReply.label(kind: .alarm, title: "绝对不能吃饭", chinese: true)
    let zh = AgentReply.receipt(.init(added: [alarm]), chinese: true)
    XCTAssertEqual(zh, "已添加闹钟“绝对不能吃饭”。不需要的话点撤销。")
    let en = AgentReply.receipt(
      .init(added: [AgentReply.label(kind: .reminder, title: "Milk", chinese: false)]),
      chinese: false)
    XCTAssertEqual(en, "Added the reminder “Milk”. Tap Undo if you don't want it.")
    for text in [zh, en] {
      XCTAssertFalse(text.contains("Add") && !text.contains("Added"), text)
      XCTAssertFalse(text.contains("点添加") || text.contains("点“添加”"), text)
    }
    let failed = AgentReply.receipt(.init(failed: ["Gym"]), chinese: false)
    XCTAssertTrue(failed.contains("draft"), failed)
    XCTAssertFalse(failed.contains("Undo"), failed)
    let waiting = AgentReply.receipt(.init(changed: ["事件“周会”"], waiting: 1), chinese: true)
    XCTAssertEqual(waiting, "已修改事件“周会”。不需要的话点撤销。这张卡片需要你确认后才会生效。")
  }

  func testNoBackgroundWrites() {
    for tool in AgentTool.allCases where tool.isWrite {
      XCTAssertEqual(
        ActionPolicy.tier(R(tool: tool, source: .background, kind: .reminder)),
        .refuse(.backgroundWrite))
    }
  }

  func testReportedSpeechNeverBecomesAnItem() {
    for kind in [ActionPolicy.Kind.reminder, .event, .alarm] {
      XCTAssertEqual(
        ActionPolicy.tier(
          R(tool: .proposeCreate, source: .agent, kind: kind, reportedSpeech: true)),
        .refuse(.reportedSpeech))
    }
    // Editing the user's own existing item is still possible in the same message.
    XCTAssertEqual(
      ActionPolicy.tier(
        R(tool: .proposeEdit, source: .agent, kind: .reminder, fields: [.due], reportedSpeech: true)
      ),
      .preview)
  }

  // MARK: Principle 2: meetings stay fixed by default

  func testEventsMoveOnlyWhenTheUserAskedAndNameWhoIsAffected() {
    var move = R(tool: .proposeEdit, source: .agent, kind: .event, fields: [.start])
    XCTAssertEqual(ActionPolicy.tier(move), .refuse(.meetingsStayFixed))
    move.userAskedToMoveEvent = true
    XCTAssertEqual(ActionPolicy.tier(move), .preview)
    move.askedForAction = true
    XCTAssertEqual(ActionPolicy.tier(move), .direct, "an attendee-free move is applied with Undo")
    move.attendees = 4
    XCTAssertEqual(ActionPolicy.tier(move), .confirmConsequence([.notifies(attendees: 4)]))
    move.affectsSeries = true
    XCTAssertEqual(
      ActionPolicy.tier(move), .confirmConsequence([.notifies(attendees: 4), .wholeSeries]))
    XCTAssertFalse(ActionPolicy.tier(move).allowsAddAll)
    // A title change does not move the meeting.
    let rename = R(tool: .proposeEdit, source: .agent, kind: .event, fields: [.title])
    XCTAssertEqual(ActionPolicy.tier(rename), .preview)
  }

  func testEventDeletesThatReachOthersConfirmTheirConsequence() {
    let delete = R(
      tool: .proposeDelete, source: .agent, kind: .event, askedForAction: true, attendees: 2)
    XCTAssertEqual(
      ActionPolicy.tier(delete), .confirmConsequence([.deletesEvent, .notifies(attendees: 2)]))
    let series = R(
      tool: .proposeDelete, source: .agent, kind: .event, askedForAction: true,
      affectsSeries: true)
    XCTAssertEqual(ActionPolicy.tier(series), .confirmConsequence([.deletesEvent, .wholeSeries]))
    let reminderDelete = R(
      tool: .proposeDelete, source: .agent, kind: .reminder, askedForAction: true)
    XCTAssertEqual(ActionPolicy.tier(reminderDelete), .direct)
  }

  // MARK: Principle 4: stopping an alarm ≠ finishing a task

  func testStoppingAnAlarmNeverCompletesATask() {
    var done = R(
      tool: .proposeEdit, source: .agent, kind: .reminder, fields: [.done], fromAlarmStop: true)
    XCTAssertEqual(ActionPolicy.tier(done), .refuse(.stoppingAlarmIsNotCompletion))
    done.fromAlarmStop = false
    XCTAssertEqual(ActionPolicy.tier(done), .preview)
  }

  // MARK: Principle 5: ideas aren't obligations

  func testNotesBecomeTasksOnlyFromMakeATask() {
    var fromNote = oneOff()
    fromNote.fromNote = true
    XCTAssertEqual(ActionPolicy.tier(fromNote), .refuse(.noteIsNotATask))
    fromNote.source = .agent
    XCTAssertEqual(ActionPolicy.tier(fromNote), .refuse(.noteIsNotATask))
    fromNote.viaMakeTask = true
    XCTAssertEqual(ActionPolicy.tier(fromNote), .direct, "the user tapped Make a task")
  }

  // MARK: Principle 6: overdue items are never silently moved

  func testOverdueRedatesHappenOnlyWhenAsked() {
    for source in [ActionPolicy.Source.fastLane, .agent, .siri] {
      let tidy = R(tool: .proposeTidy, source: source, kind: .reminder, fields: [.due])
      XCTAssertEqual(ActionPolicy.tier(tidy), .preview)
      XCTAssertTrue(ActionPolicy.tier(tidy).allowsAddAll)
    }
    let asked = R(
      tool: .proposeTidy, source: .agent, kind: .reminder, fields: [.due], askedForAction: true)
    XCTAssertEqual(ActionPolicy.tier(asked), .direct)
  }

  // MARK: Apply-time recheck (§4.2, M1)

  func testRecheckVoidsStaleCardsAndReconfirmsHigherStakes() {
    var move = R(
      tool: .proposeEdit, source: .agent, kind: .event, fields: [.start],
      userAskedToMoveEvent: true)
    let shown = ActionPolicy.tier(move)
    XCTAssertEqual(ActionPolicy.recheck(shown: shown, now: move), .apply)
    move.attendees = 3
    XCTAssertEqual(
      ActionPolicy.recheck(shown: shown, now: move),
      .reconfirm(.confirmConsequence([.notifies(attendees: 3)])))
    let confirmed = ActionPolicy.tier(move)
    move.attendees = 5
    XCTAssertEqual(
      ActionPolicy.recheck(shown: confirmed, now: move),
      .reconfirm(.confirmConsequence([.notifies(attendees: 5)])))
    move.changedSincePreview = true
    XCTAssertEqual(ActionPolicy.recheck(shown: confirmed, now: move), .void(.changedSincePreview))
    var reminder = oneOff()
    XCTAssertEqual(ActionPolicy.recheck(shown: .direct, now: reminder), .apply)
    reminder.changedSincePreview = true
    XCTAssertEqual(ActionPolicy.tier(reminder), .refuse(.changedSincePreview))
  }

  func testPreviewFirstKeepsAClearRequestOnItsCard() {
    func request(previewFirst: Bool, attendees: Int = 0) -> ActionPolicy.Request {
      ActionPolicy.Request(
        tool: .proposeEdit, source: .agent, kind: .event, fields: [.title],
        askedForAction: true, attendees: attendees, previewFirst: previewFirst)
    }
    XCTAssertEqual(ActionPolicy.tier(request(previewFirst: false)), .direct)
    XCTAssertEqual(ActionPolicy.tier(request(previewFirst: true)), .preview)
    XCTAssertEqual(
      ActionPolicy.tier(request(previewFirst: true, attendees: 2)),
      ActionPolicy.tier(request(previewFirst: false, attendees: 2)))
    XCTAssertEqual(
      ActionPolicy.tier(
        ActionPolicy.Request(
          tool: .proposeCreate, source: .fastLane, kind: .reminder, askedForAction: true,
          previewFirst: true)), .preview)
    XCTAssertEqual(
      ActionPolicy.recheck(shown: .preview, now: request(previewFirst: true)), .apply)
  }
}

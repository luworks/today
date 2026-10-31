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
      clearOneOffReminder: true)
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

  // MARK: Principle 1: AI prepares, the user decides

  func testDirectOnlyForTheFastLaneClearOneOffReminderInTheUsersOwnWords() {
    XCTAssertEqual(ActionPolicy.tier(oneOff()), .direct)
    XCTAssertEqual(ActionPolicy.tier(oneOff(source: .agent)), .preview)
    XCTAssertEqual(ActionPolicy.tier(oneOff(source: .siri)), .preview)
    XCTAssertEqual(ActionPolicy.tier(oneOff(words: .derived)), .preview)
    var unclear = oneOff()
    unclear.clearOneOffReminder = false
    XCTAssertEqual(ActionPolicy.tier(unclear), .preview)
  }

  func testRecurrenceAlarmsEventsAndEditsAreNeverDirect() {
    var repeating = oneOff()
    repeating.fields.insert(.repeatRule)
    var ringing = oneOff()
    ringing.fields.insert(.ringsAsAlarm)
    var alarm = oneOff()
    alarm.kind = .alarm
    var event = oneOff()
    event.kind = .event
    var edit = oneOff()
    edit.tool = .proposeEdit
    var tidy = oneOff()
    tidy.tool = .proposeTidy
    var undo = oneOff()
    undo.tool = .proposeUndo
    for request in [repeating, ringing, alarm, event, edit, tidy, undo] {
      XCTAssertEqual(ActionPolicy.tier(request), .preview, "\(request)")
    }
    // Exhaustively: nothing other than the one-off reminder create is ever direct.
    for tool in AgentTool.allCases where tool.isWrite {
      for source in [ActionPolicy.Source.fastLane, .agent, .siri] {
        for kind in [ActionPolicy.Kind.reminder, .event, .alarm, .list] {
          var r = R(tool: tool, source: source, kind: kind, clearOneOffReminder: true)
          r.userAskedToMoveEvent = true
          let isTheException =
            tool == .proposeCreate && source == .fastLane && kind == .reminder
          XCTAssertEqual(
            ActionPolicy.tier(r) == .direct, isTheException, "\(tool) \(source) \(kind)")
        }
      }
    }
  }

  func testNoBackgroundWrites() {
    for tool in AgentTool.allCases where tool.isWrite {
      XCTAssertEqual(
        ActionPolicy.tier(R(tool: tool, source: .background, kind: .reminder)),
        .refuse(.backgroundWrite))
    }
  }

  // MARK: Principle 2: meetings stay fixed by default

  func testEventsMoveOnlyWhenTheUserAskedAndNameWhoIsAffected() {
    var move = R(tool: .proposeEdit, source: .agent, kind: .event, fields: [.start])
    XCTAssertEqual(ActionPolicy.tier(move), .refuse(.meetingsStayFixed))
    move.userAskedToMoveEvent = true
    XCTAssertEqual(ActionPolicy.tier(move), .preview)
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

  func testEventDeletesConfirmTheirConsequence() {
    let delete = R(tool: .proposeDelete, source: .agent, kind: .event, attendees: 2)
    XCTAssertEqual(
      ActionPolicy.tier(delete), .confirmConsequence([.deletesEvent, .notifies(attendees: 2)]))
    let reminderDelete = R(tool: .proposeDelete, source: .agent, kind: .reminder)
    XCTAssertEqual(ActionPolicy.tier(reminderDelete), .preview)
  }

  // MARK: Principle 3: one date per reminder

  func testThePlannedTimeIsRetired() {
    for source in [ActionPolicy.Source.fastLane, .agent] {
      XCTAssertEqual(
        ActionPolicy.tier(
          R(tool: .proposeEdit, source: source, kind: .reminder, fields: [.plannedStart])),
        .refuse(.plannedTimeRetired))
    }
    XCTAssertEqual(
      ActionPolicy.tier(R(tool: .proposeEdit, source: .agent, kind: .reminder, fields: [.due])),
      .preview)
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
    XCTAssertEqual(ActionPolicy.tier(fromNote), .preview)
    fromNote.source = .fastLane
    XCTAssertEqual(ActionPolicy.tier(fromNote), .preview, "a note is never written directly")
  }

  // MARK: Principle 6: overdue items are never silently moved

  func testOverdueRedatesAreAlwaysShown() {
    for source in [ActionPolicy.Source.fastLane, .agent, .siri] {
      let tidy = R(tool: .proposeTidy, source: source, kind: .reminder, fields: [.due])
      XCTAssertEqual(ActionPolicy.tier(tidy), .preview)
      XCTAssertTrue(ActionPolicy.tier(tidy).allowsAddAll)
    }
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
}
